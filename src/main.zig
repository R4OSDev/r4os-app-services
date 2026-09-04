const r4os = @import("r4os");

const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
        };
    }
};

const max_services = 16;
const bg: u32 = 0xD8D0C8;
const panel: u32 = 0xFFFFFF;
const panel_shadow: u32 = 0x808080;
const panel_light: u32 = 0xFFFFFF;
const header_bg: u32 = 0x0A246A;
const header_text: u32 = 0xFFFFFF;
const selected_bg: u32 = 0x0A246A;
const selected_text: u32 = 0xFFFFFF;
const text: u32 = 0x000000;
const muted: u32 = 0x606060;
const danger: u32 = 0xA00000;
const ok_green: u32 = 0x007020;
const row_h: i32 = 20;
const toolbar_h: i32 = 40;
const status_h: i32 = 22;
const details_h: i32 = 86;
const button_w: i32 = 68;
const button_h: i32 = 22;
const button_gap: i32 = 6;

const palette = r4os.gui.Palette{
    .text = text,
    .disabled_text = muted,
    .face = bg,
    .face_light = panel_light,
    .face_shadow = panel_shadow,
    .client_bg = panel,
    .select_bg = selected_bg,
    .select_text = selected_text,
    .title_bg = header_bg,
    .title_text = header_text,
};

const Action = enum(u8) {
    start,
    stop,
    restart,
    enable,
    auto,
    disable,
    install,
    remove,
    refresh,
};

const InstallFocus = enum(u8) {
    name,
    path,
    args,
    description,
    ok,
    cancel,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 720,
    h: i32 = 420,
    should_exit: bool = false,
    selected: usize = 0,
    count: usize = 0,
    services: [max_services]r4os.abi.ServiceDetail = .{r4os.abi.ServiceDetail{}} ** max_services,
    status: [128]u8 = .{0} ** 128,
    mouse_down_action: ?Action = null,
    mouse_down_install: ?InstallFocus = null,
    install_open: bool = false,
    install_focus: InstallFocus = .name,
    install_name: r4os.gui.TextField(24) = .{},
    install_path: r4os.gui.TextField(96) = .{},
    install_args: r4os.gui.TextField(80) = .{},
    install_description: r4os.gui.TextField(72) = .{},

    fn run(self: *App) i32 {
        const args = trim(zSlice(self.ctx.sys.argsRaw()));
        if (argsContain(args, "/SELFTEST") or argsContain(args, "SELFTEST")) return self.selfTest();
        if (args.len != 0) return self.runCommand(args);
        if (self.ctx.desk.programWindowId() >= 0) return self.runHosted();
        self.printList();
        return 0;
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Services");
        _ = self.ctx.desk.guiSetMinSize(700, 360);
        self.reload();
        self.updateMetrics();
        self.render();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        self.updateMetrics();
                        self.render();
                    },
                    .mouse_down => self.handleMouseDown(event.x, event.y),
                    .mouse_up => self.handleMouseUp(event.x, event.y),
                    .key_down => self.handleKey(@intCast(event.key & 0xFF)),
                    else => {},
                }
            }
            self.ctx.sys.sleepTicks(3);
        }
        return 0;
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = @max(canvas.w, 700);
        self.h = @max(canvas.h, 360);
    }

    fn reload(self: *App) void {
        self.count = 0;
        var index: u32 = 0;
        while (self.count < self.services.len) : (index += 1) {
            var detail: r4os.abi.ServiceDetail = .{};
            const rc = self.ctx.sys.serviceDetail(index, &detail);
            if (rc <= 0) break;
            self.services[self.count] = detail;
            self.count += 1;
        }
        if (self.count == 0) {
            self.selected = 0;
            self.setStatus("No registered services.");
        } else {
            if (self.selected >= self.count) self.selected = self.count - 1;
            self.setStatus("Ready.");
        }
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [192]u8 = .{0} ** 192;
        _ = canvas.clear(bg);
        self.drawToolbar(canvas, scratch[0..]);
        self.drawList(canvas, scratch[0..]);
        self.drawDetails(canvas, scratch[0..]);
        self.drawStatus(canvas, scratch[0..]);
        if (self.install_open) self.drawInstallDialog(canvas, scratch[0..]);
        _ = paint.present();
    }

    fn drawToolbar(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        _ = canvas.rect(.{ .x = 0, .y = 0, .w = self.w, .h = toolbar_h }, bg);
        self.drawActionButton(canvas, scratch, .start, "Start");
        self.drawActionButton(canvas, scratch, .stop, "Stop");
        self.drawActionButton(canvas, scratch, .restart, "Restart");
        self.drawActionButton(canvas, scratch, .enable, "Enable");
        self.drawActionButton(canvas, scratch, .auto, "Auto");
        self.drawActionButton(canvas, scratch, .disable, "Disable");
        self.drawActionButton(canvas, scratch, .install, "Install");
        self.drawActionButton(canvas, scratch, .remove, "Remove");
        self.drawActionButton(canvas, scratch, .refresh, "Refresh");
    }

    fn drawActionButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, action: Action, label: []const u8) void {
        _ = canvas.button(.{
            .rect = self.actionRect(action),
            .text = label,
            .state = if (self.actionDisabled(action)) .disabled else if (self.mouse_down_action != null and self.mouse_down_action.? == action) .pressed else .normal,
        }, scratch);
    }

    fn drawList(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.listRect();
        _ = canvas.rect(rect, panel_shadow);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, panel);
        const header = self.headerRect();
        _ = canvas.rect(header, header_bg);
        _ = canvas.text(header.x + 6, header.y + 5, "Name", header_text, header_bg);
        _ = canvas.text(header.x + 150, header.y + 5, "Status", header_text, header_bg);
        _ = canvas.text(header.x + 244, header.y + 5, "Start", header_text, header_bg);
        _ = canvas.text(header.x + 330, header.y + 5, "Instance", header_text, header_bg);
        _ = canvas.text(header.x + 410, header.y + 5, "Restarts", header_text, header_bg);
        _ = canvas.text(header.x + 500, header.y + 5, "Path", header_text, header_bg);

        var row: usize = 0;
        while (row < self.visibleRows() and row < self.count) : (row += 1) {
            self.drawServiceRow(canvas, scratch, row);
        }
    }

    fn drawServiceRow(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, row: usize) void {
        const detail = &self.services[row];
        const rect = self.rowRect(row);
        const selected_row = row == self.selected;
        const bg_color = if (selected_row) selected_bg else panel;
        const fg_color = if (selected_row) selected_text else text;
        _ = canvas.rect(rect, bg_color);
        _ = canvas.textClipped(rect.x + 6, rect.y + 4, 136, scratch, spanZ(detail.info.name[0..]), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 150, rect.y + 4, 86, scratch, serviceStateName(detail.info.state), serviceStateColor(detail.info.state, fg_color), bg_color);
        _ = canvas.textClipped(rect.x + 244, rect.y + 4, 78, scratch, serviceStartName(detail.info.start_mode), fg_color, bg_color);
        numberText(scratch, @intCast(detail.info.instance_id));
        _ = canvas.textClipped(rect.x + 330, rect.y + 4, 72, scratch, spanZ(scratch), fg_color, bg_color);
        numberText(scratch, @intCast(detail.info.restart_count));
        _ = canvas.textClipped(rect.x + 410, rect.y + 4, 82, scratch, spanZ(scratch), fg_color, bg_color);
        _ = canvas.textClipped(rect.x + 500, rect.y + 4, rect.w - 506, scratch, spanZ(detail.path[0..]), fg_color, bg_color);
    }

    fn drawDetails(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.detailsRect();
        _ = canvas.groupBox(.{ .rect = rect, .title = "Details" }, scratch);
        if (self.count == 0) return;
        const detail = &self.services[self.selected];
        var line: [160]u8 = .{0} ** 160;
        setZ(line[0..], "Name: ");
        appendZ(line[0..], spanZ(detail.info.name[0..]));
        appendZ(line[0..], "   Status: ");
        appendZ(line[0..], serviceStateName(detail.info.state));
        appendZ(line[0..], "   Start: ");
        appendZ(line[0..], serviceStartName(detail.info.start_mode));
        _ = canvas.textClipped(rect.x + 12, rect.y + 22, rect.w - 24, scratch, spanZ(line[0..]), text, bg);

        setZ(line[0..], "Path: ");
        appendZ(line[0..], spanZ(detail.path[0..]));
        _ = canvas.textClipped(rect.x + 12, rect.y + 42, rect.w - 24, scratch, spanZ(line[0..]), text, bg);

        setZ(line[0..], "Args: ");
        appendZ(line[0..], spanZ(detail.args[0..]));
        _ = canvas.textClipped(rect.x + 12, rect.y + 62, @divTrunc(rect.w - 28, 2), scratch, spanZ(line[0..]), text, bg);

        setZ(line[0..], "Error: ");
        appendZ(line[0..], spanZ(detail.info.last_error[0..]));
        _ = canvas.textClipped(rect.x + @divTrunc(rect.w, 2), rect.y + 62, @divTrunc(rect.w - 28, 2), scratch, spanZ(line[0..]), danger, bg);
    }

    fn drawStatus(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        const rect = self.statusRect();
        _ = canvas.rect(rect, 0xC0C0C0);
        _ = canvas.rect(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, bg);
        _ = canvas.textClipped(rect.x + 6, rect.y + 5, rect.w - 12, scratch, spanZ(self.status[0..]), text, bg);
    }

    fn drawInstallDialog(self: *App, canvas: r4os.gui.Canvas, scratch: []u8) void {
        self.syncInstallFocus();
        const rect = self.installDialogRect();
        _ = canvas.rect(.{ .x = rect.x + 3, .y = rect.y + 3, .w = rect.w, .h = rect.h }, panel_shadow);
        _ = canvas.rect(rect, bg);
        _ = canvas.rect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 20 }, header_bg);
        _ = canvas.text(rect.x + 8, rect.y + 5, "Install service", header_text, header_bg);
        self.drawInstallField(canvas, scratch, "Name:", self.installNameRect(), &self.install_name);
        self.drawInstallField(canvas, scratch, "Path:", self.installPathRect(), &self.install_path);
        self.drawInstallField(canvas, scratch, "Args:", self.installArgsRect(), &self.install_args);
        self.drawInstallField(canvas, scratch, "Description:", self.installDescriptionRect(), &self.install_description);
        self.drawInstallButton(canvas, scratch, .ok, "OK");
        self.drawInstallButton(canvas, scratch, .cancel, "Cancel");
    }

    fn drawInstallField(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, label: []const u8, rect: r4os.gui.Rect, field: anytype) void {
        _ = self;
        _ = canvas.label(.{ .rect = .{ .x = rect.x - 104, .y = rect.y + 4, .w = 96, .h = 16 }, .text = label, .alignment = .right, .fg = text, .bg = bg }, scratch);
        _ = field.draw(canvas, rect, scratch);
    }

    fn drawInstallButton(self: *App, canvas: r4os.gui.Canvas, scratch: []u8, focus: InstallFocus, label: []const u8) void {
        _ = canvas.button(.{
            .rect = self.installButtonRect(focus),
            .text = label,
            .state = if (self.mouse_down_install != null and self.mouse_down_install.? == focus) .pressed else .normal,
            .focused = self.install_focus == focus,
            .is_default = focus == .ok,
            .is_cancel = focus == .cancel,
        }, scratch);
    }

    fn handleMouseDown(self: *App, x: i32, y: i32) void {
        self.mouse_down_action = null;
        self.mouse_down_install = null;
        if (self.install_open) {
            if (self.installNameRect().contains(x, y)) return self.setInstallFocus(.name);
            if (self.installPathRect().contains(x, y)) return self.setInstallFocus(.path);
            if (self.installArgsRect().contains(x, y)) return self.setInstallFocus(.args);
            if (self.installDescriptionRect().contains(x, y)) return self.setInstallFocus(.description);
            if (self.installButtonRect(.ok).contains(x, y)) return self.pressInstall(.ok);
            if (self.installButtonRect(.cancel).contains(x, y)) return self.pressInstall(.cancel);
            self.render();
            return;
        }
        if (self.selectRowAt(x, y)) return;
        if (self.actionAt(x, y)) |action| {
            if (!self.actionDisabled(action)) {
                self.mouse_down_action = action;
                self.render();
            }
        }
    }

    fn handleMouseUp(self: *App, x: i32, y: i32) void {
        if (self.install_open) {
            if (self.mouse_down_install) |focus| {
                const hit = self.installButtonRect(focus).contains(x, y);
                self.mouse_down_install = null;
                if (hit) self.activateInstall(focus);
                self.render();
            }
            return;
        }
        if (self.mouse_down_action) |action| {
            const hit = self.actionRect(action).contains(x, y);
            self.mouse_down_action = null;
            if (hit and !self.actionDisabled(action)) self.activate(action);
            self.render();
        }
    }

    fn handleKey(self: *App, key: u8) void {
        if (self.install_open) return self.handleInstallKey(key);
        switch (key) {
            r4os.gui.Key.escape => self.should_exit = true,
            r4os.gui.Key.up => {
                if (self.selected > 0) self.selected -= 1;
                self.render();
            },
            r4os.gui.Key.down => {
                if (self.selected + 1 < self.count) self.selected += 1;
                self.render();
            },
            r4os.gui.Key.home => {
                self.selected = 0;
                self.render();
            },
            r4os.gui.Key.end => {
                if (self.count > 0) self.selected = self.count - 1;
                self.render();
            },
            'r', 'R' => {
                self.reload();
                self.render();
            },
            else => {},
        }
    }

    fn handleInstallKey(self: *App, key: u8) void {
        if (key == r4os.gui.Key.escape) {
            self.install_open = false;
            self.render();
            return;
        }
        if (key == r4os.gui.Key.tab or key == r4os.gui.Key.shift_tab) {
            self.nextInstallFocus(key == r4os.gui.Key.shift_tab);
            self.render();
            return;
        }
        if (key == r4os.gui.Key.enter) {
            if (self.install_focus == .ok or self.install_focus == .cancel) self.activateInstall(self.install_focus);
            self.render();
            return;
        }
        const changed = switch (self.install_focus) {
            .name => self.install_name.handleClipboardKey(&self.ctx.desk, key),
            .path => self.install_path.handleClipboardKey(&self.ctx.desk, key),
            .args => self.install_args.handleClipboardKey(&self.ctx.desk, key),
            .description => self.install_description.handleClipboardKey(&self.ctx.desk, key),
            else => false,
        };
        if (changed) self.render();
    }

    fn activate(self: *App, action: Action) void {
        if (action == .refresh) {
            self.reload();
            return;
        }
        if (action == .install) {
            self.openInstallDialog();
            return;
        }
        if (self.count == 0) return;
        const name = spanZ(self.services[self.selected].info.name[0..]);
        var name_z: [r4os.abi.service_name_bytes + 1]u8 = .{0} ** (r4os.abi.service_name_bytes + 1);
        const name_ptr = makeZ(name_z[0..], name) orelse {
            self.setStatus("Service name invalid.");
            return;
        };
        var info: r4os.abi.ServiceInfo = .{};
        const rc = switch (action) {
            .start => self.ctx.sys.serviceStart(name_ptr, &info),
            .stop => self.ctx.sys.serviceStop(name_ptr, &info, 40),
            .restart => self.ctx.sys.serviceRestart(name_ptr, &info),
            .enable => self.ctx.sys.serviceSetStartMode(name_ptr, r4os.abi.service_start_manual, &info),
            .auto => self.ctx.sys.serviceSetStartMode(name_ptr, r4os.abi.service_start_auto, &info),
            .disable => self.ctx.sys.serviceSetStartMode(name_ptr, r4os.abi.service_start_disabled, &info),
            .remove => self.ctx.sys.serviceRemove(name_ptr),
            else => r4os.abi.service_api_result_invalid,
        };
        self.setActionStatus(action, rc);
        self.reload();
    }

    fn openInstallDialog(self: *App) void {
        self.install_name.set("NEWSVC");
        self.install_path.set("C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SVCAPPD.R4X");
        self.install_args.set("/HOLD");
        self.install_description.set("R4X-Service");
        self.install_focus = .name;
        self.install_open = true;
    }

    fn activateInstall(self: *App, focus: InstallFocus) void {
        if (focus == .cancel) {
            self.install_open = false;
            self.setStatus("Installation abgebrochen.");
            return;
        }
        var name_z: [r4os.abi.service_name_bytes + 1]u8 = .{0} ** (r4os.abi.service_name_bytes + 1);
        var path_z: [r4os.abi.service_path_bytes + 1]u8 = .{0} ** (r4os.abi.service_path_bytes + 1);
        var args_z: [r4os.abi.service_args_bytes + 1]u8 = .{0} ** (r4os.abi.service_args_bytes + 1);
        var desc_z: [r4os.abi.service_description_bytes + 1]u8 = .{0} ** (r4os.abi.service_description_bytes + 1);
        const name_ptr = makeZ(name_z[0..], trim(self.install_name.value())) orelse return self.setStatus("Name too long.");
        const path_ptr = makeZ(path_z[0..], trim(self.install_path.value())) orelse return self.setStatus("Path too long.");
        const args_ptr = makeZ(args_z[0..], trim(self.install_args.value())) orelse return self.setStatus("Args too long.");
        const desc_ptr = makeZ(desc_z[0..], trim(self.install_description.value())) orelse return self.setStatus("Description too long.");
        var info: r4os.abi.ServiceInfo = .{};
        const rc = self.ctx.sys.serviceInstall(name_ptr, path_ptr, args_ptr, r4os.abi.service_start_manual, desc_ptr, &info);
        self.setActionStatus(.install, rc);
        if (rc == r4os.abi.service_api_result_ok) self.install_open = false;
        self.reload();
    }

    fn selfTest(self: *App) i32 {
        self.ctx.sys.println("SERVICES selftest");
        if (!self.ctx.sys.hasFn("service_start")) return self.fail("api-version");
        self.cleanupTempService();

        var detail: r4os.abi.ServiceDetail = .{};
        if (self.ctx.sys.serviceDetail(0, &detail) <= 0) return self.fail("enumeration");
        if (sameBytes(spanZ(detail.info.name[0..]), "net.dhcp")) return self.fail("kernel-service-listed");

        var info: r4os.abi.ServiceInfo = .{};
        var rc = self.ctx.sys.serviceInstall("SVCTEMP", "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SVCAPPD.R4X", "/HOLD", r4os.abi.service_start_manual, "Services selftest", &info);
        if (rc != r4os.abi.service_api_result_ok) return self.failCode("install", rc);
        rc = self.ctx.sys.serviceStart("SVCTEMP", &info);
        if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running or info.instance_id == 0) return self.failCode("start", rc);
        rc = self.ctx.sys.serviceRestart("SVCTEMP", &info);
        if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_running or info.restart_count == 0) return self.failCode("restart", rc);
        rc = self.ctx.sys.serviceStop("SVCTEMP", &info, 60);
        if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_stopped) return self.failCode("stop", rc);
        rc = self.ctx.sys.serviceSetStartMode("SVCTEMP", r4os.abi.service_start_disabled, &info);
        if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_disabled) return self.failCode("disable", rc);
        rc = self.ctx.sys.serviceSetStartMode("SVCTEMP", r4os.abi.service_start_manual, &info);
        if (rc != r4os.abi.service_api_result_ok or info.state != r4os.abi.service_state_stopped) return self.failCode("enable", rc);
        rc = self.ctx.sys.serviceRemove("SVCTEMP");
        if (rc != r4os.abi.service_api_result_ok) return self.failCode("remove", rc);
        rc = self.ctx.sys.serviceStatus("SVCTEMP", &info);
        if (rc != r4os.abi.service_api_result_not_found) return self.failCode("remove-status", rc);
        self.ctx.sys.println("SERVICES selftest: OK");
        return 0;
    }

    fn cleanupTempService(self: *App) void {
        var info: r4os.abi.ServiceInfo = .{};
        const rc = self.ctx.sys.serviceStatus("SVCTEMP", &info);
        if (rc == r4os.abi.service_api_result_ok) {
            if (info.state == r4os.abi.service_state_running or info.state == r4os.abi.service_state_starting or info.state == r4os.abi.service_state_stopping) {
                _ = self.ctx.sys.serviceStop("SVCTEMP", &info, 60);
            }
            _ = self.ctx.sys.serviceRemove("SVCTEMP");
        }
    }

    fn fail(self: *App, label: []const u8) i32 {
        self.ctx.sys.write("SERVICES selftest FAILED: ");
        self.ctx.sys.println(label);
        return 1;
    }

    fn failCode(self: *App, label: []const u8, code: i32) i32 {
        self.ctx.sys.write("SERVICES selftest FAILED: ");
        self.ctx.sys.write(label);
        self.ctx.sys.write(" code=");
        self.ctx.sys.printI32(code);
        self.ctx.sys.println("");
        _ = self.ctx.sys.serviceRemove("SVCTEMP");
        return 1;
    }

    fn runCommand(self: *App, args: []const u8) i32 {
        const first = takeToken(args) orelse return 0;
        if (tokenEquals(first.token, "/LIST") or tokenEquals(first.token, "LIST")) {
            self.printList();
            return 0;
        }
        if (tokenEquals(first.token, "/INSTALL") or tokenEquals(first.token, "INSTALL")) return self.commandInstall(first.rest);
        if (tokenEquals(first.token, "/REMOVE") or tokenEquals(first.token, "REMOVE")) return self.commandOne(first.rest, .remove);
        if (tokenEquals(first.token, "/START") or tokenEquals(first.token, "START")) return self.commandOne(first.rest, .start);
        if (tokenEquals(first.token, "/STOP") or tokenEquals(first.token, "STOP")) return self.commandOne(first.rest, .stop);
        if (tokenEquals(first.token, "/RESTART") or tokenEquals(first.token, "RESTART")) return self.commandOne(first.rest, .restart);
        if (tokenEquals(first.token, "/ENABLE") or tokenEquals(first.token, "ENABLE")) return self.commandOne(first.rest, .enable);
        if (tokenEquals(first.token, "/AUTO") or tokenEquals(first.token, "AUTO")) return self.commandOne(first.rest, .auto);
        if (tokenEquals(first.token, "/DISABLE") or tokenEquals(first.token, "DISABLE")) return self.commandOne(first.rest, .disable);
        self.printUsage();
        return 1;
    }

    fn commandOne(self: *App, rest_raw: []const u8, action: Action) i32 {
        const part = takeToken(rest_raw) orelse {
            self.printUsage();
            return 1;
        };
        var name_z: [r4os.abi.service_name_bytes + 1]u8 = .{0} ** (r4os.abi.service_name_bytes + 1);
        const name_ptr = makeZ(name_z[0..], part.token) orelse return 1;
        var info: r4os.abi.ServiceInfo = .{};
        const rc = switch (action) {
            .start => self.ctx.sys.serviceStart(name_ptr, &info),
            .stop => self.ctx.sys.serviceStop(name_ptr, &info, 40),
            .restart => self.ctx.sys.serviceRestart(name_ptr, &info),
            .enable => self.ctx.sys.serviceSetStartMode(name_ptr, r4os.abi.service_start_manual, &info),
            .auto => self.ctx.sys.serviceSetStartMode(name_ptr, r4os.abi.service_start_auto, &info),
            .disable => self.ctx.sys.serviceSetStartMode(name_ptr, r4os.abi.service_start_disabled, &info),
            .remove => self.ctx.sys.serviceRemove(name_ptr),
            else => r4os.abi.service_api_result_invalid,
        };
        self.printCommandResult(action, part.token, rc);
        return if (rc == r4os.abi.service_api_result_ok) 0 else 1;
    }

    fn commandInstall(self: *App, rest_raw: []const u8) i32 {
        const name_part = takeToken(rest_raw) orelse {
            self.printUsage();
            return 1;
        };
        const path_part = takeToken(name_part.rest) orelse {
            self.printUsage();
            return 1;
        };
        var args_value: [r4os.abi.service_args_bytes]u8 = .{0} ** r4os.abi.service_args_bytes;
        var desc_value: [r4os.abi.service_description_bytes]u8 = .{0} ** r4os.abi.service_description_bytes;
        var mode: u32 = r4os.abi.service_start_manual;
        var rest = path_part.rest;
        while (takeToken(rest)) |part| {
            if (tokenEquals(part.token, "/AUTO")) mode = r4os.abi.service_start_auto else if (tokenEquals(part.token, "/DISABLED") or tokenEquals(part.token, "/DISABLE")) mode = r4os.abi.service_start_disabled else if (startsWithIgnoreCase(part.token, "/ARGS=")) setZ(args_value[0..], part.token[6..]) else if (startsWithIgnoreCase(part.token, "/DESC=")) setZ(desc_value[0..], part.token[6..]);
            rest = part.rest;
        }

        var name_z: [r4os.abi.service_name_bytes + 1]u8 = .{0} ** (r4os.abi.service_name_bytes + 1);
        var path_z: [r4os.abi.service_path_bytes + 1]u8 = .{0} ** (r4os.abi.service_path_bytes + 1);
        var args_z: [r4os.abi.service_args_bytes + 1]u8 = .{0} ** (r4os.abi.service_args_bytes + 1);
        var desc_z: [r4os.abi.service_description_bytes + 1]u8 = .{0} ** (r4os.abi.service_description_bytes + 1);
        const name_ptr = makeZ(name_z[0..], name_part.token) orelse return 1;
        const path_ptr = makeZ(path_z[0..], path_part.token) orelse return 1;
        const args_ptr = makeZ(args_z[0..], spanZ(args_value[0..])) orelse return 1;
        const desc_ptr = makeZ(desc_z[0..], spanZ(desc_value[0..])) orelse return 1;
        var info: r4os.abi.ServiceInfo = .{};
        const rc = self.ctx.sys.serviceInstall(name_ptr, path_ptr, args_ptr, mode, desc_ptr, &info);
        self.printCommandResult(.install, name_part.token, rc);
        return if (rc == r4os.abi.service_api_result_ok) 0 else 1;
    }

    fn printList(self: *App) void {
        self.ctx.sys.println("SERVICES");
        var index: u32 = 0;
        var shown: u32 = 0;
        while (true) : (index += 1) {
            var detail: r4os.abi.ServiceDetail = .{};
            const rc = self.ctx.sys.serviceDetail(index, &detail);
            if (rc <= 0) break;
            shown += 1;
            self.ctx.sys.write("  ");
            self.ctx.sys.write(spanZ(detail.info.name[0..]));
            self.ctx.sys.write(" state=");
            self.ctx.sys.write(serviceStateName(detail.info.state));
            self.ctx.sys.write(" start=");
            self.ctx.sys.write(serviceStartName(detail.info.start_mode));
            self.ctx.sys.write(" path=");
            self.ctx.sys.write(spanZ(detail.path[0..]));
            self.ctx.sys.println("");
        }
        if (shown == 0) self.ctx.sys.println("  No registered services.");
    }

    fn printUsage(self: *App) void {
        self.ctx.sys.println("Usage: SERVICES [/LIST|/START name|/STOP name|/RESTART name]");
        self.ctx.sys.println("                [/ENABLE name|/AUTO name|/DISABLE name|/REMOVE name]");
        self.ctx.sys.println("                [/INSTALL name path [/ARGS=x] [/AUTO|/DISABLED] [/DESC=x]]");
    }

    fn printCommandResult(self: *App, action: Action, name: []const u8, rc: i32) void {
        self.ctx.sys.write("SERVICES ");
        self.ctx.sys.write(actionName(action));
        self.ctx.sys.write(" ");
        self.ctx.sys.write(name);
        self.ctx.sys.write(": ");
        self.ctx.sys.println(resultName(rc));
    }

    fn actionDisabled(self: *const App, action: Action) bool {
        if (action == .install or action == .refresh) return false;
        return self.count == 0;
    }

    fn actionAt(self: *const App, x: i32, y: i32) ?Action {
        inline for (action_order) |action| {
            if (self.actionRect(action).contains(x, y)) return action;
        }
        return null;
    }

    fn selectRowAt(self: *App, x: i32, y: i32) bool {
        if (!self.listRect().contains(x, y)) return false;
        if (y < self.firstRowY()) return false;
        const raw: usize = @intCast(@divTrunc(y - self.firstRowY(), row_h));
        if (raw >= self.count or raw >= self.visibleRows()) return false;
        self.selected = raw;
        self.render();
        return true;
    }

    fn setActionStatus(self: *App, action: Action, rc: i32) void {
        var line: [128]u8 = .{0} ** 128;
        setZ(line[0..], actionName(action));
        appendZ(line[0..], ": ");
        appendZ(line[0..], resultName(rc));
        self.setStatus(spanZ(line[0..]));
    }

    fn setStatus(self: *App, value: []const u8) void {
        setZ(self.status[0..], value);
    }

    fn syncInstallFocus(self: *App) void {
        self.install_name.focused = self.install_focus == .name;
        self.install_path.focused = self.install_focus == .path;
        self.install_args.focused = self.install_focus == .args;
        self.install_description.focused = self.install_focus == .description;
    }

    fn setInstallFocus(self: *App, focus: InstallFocus) void {
        self.install_focus = focus;
        self.render();
    }

    fn pressInstall(self: *App, focus: InstallFocus) void {
        self.install_focus = focus;
        self.mouse_down_install = focus;
        self.render();
    }

    fn nextInstallFocus(self: *App, previous: bool) void {
        const raw: u8 = @intFromEnum(self.install_focus);
        const next = if (previous)
            if (raw == 0) @as(u8, 5) else raw - 1
        else if (raw >= 5)
            @as(u8, 0)
        else
            raw + 1;
        self.install_focus = @enumFromInt(next);
    }

    fn actionRect(self: *const App, action: Action) r4os.gui.Rect {
        _ = self;
        const idx: i32 = @intCast(actionIndex(action));
        return .{ .x = 8 + idx * (button_w + button_gap), .y = 9, .w = button_w, .h = button_h };
    }

    fn listRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = toolbar_h, .w = self.w - 16, .h = self.h - toolbar_h - details_h - status_h - 8 };
    }

    fn headerRect(self: *const App) r4os.gui.Rect {
        const rect = self.listRect();
        return .{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = row_h };
    }

    fn firstRowY(self: *const App) i32 {
        return self.headerRect().y + row_h;
    }

    fn rowRect(self: *const App, row: usize) r4os.gui.Rect {
        const rect = self.listRect();
        return .{ .x = rect.x + 1, .y = self.firstRowY() + @as(i32, @intCast(row)) * row_h, .w = rect.w - 2, .h = row_h };
    }

    fn visibleRows(self: *const App) usize {
        const rows = @divTrunc(self.listRect().h - row_h - 2, row_h);
        return if (rows <= 0) 0 else @intCast(rows);
    }

    fn detailsRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = self.h - details_h - status_h - 4, .w = self.w - 16, .h = details_h };
    }

    fn statusRect(self: *const App) r4os.gui.Rect {
        return .{ .x = 8, .y = self.h - status_h - 4, .w = self.w - 16, .h = status_h };
    }

    fn installDialogRect(self: *const App) r4os.gui.Rect {
        const w: i32 = 540;
        const h: i32 = 196;
        return .{ .x = @divTrunc(self.w - w, 2), .y = @divTrunc(self.h - h, 2), .w = w, .h = h };
    }

    fn installNameRect(self: *const App) r4os.gui.Rect {
        const rect = self.installDialogRect();
        return .{ .x = rect.x + 128, .y = rect.y + 34, .w = rect.w - 148, .h = 20 };
    }

    fn installPathRect(self: *const App) r4os.gui.Rect {
        const rect = self.installDialogRect();
        return .{ .x = rect.x + 128, .y = rect.y + 60, .w = rect.w - 148, .h = 20 };
    }

    fn installArgsRect(self: *const App) r4os.gui.Rect {
        const rect = self.installDialogRect();
        return .{ .x = rect.x + 128, .y = rect.y + 86, .w = rect.w - 148, .h = 20 };
    }

    fn installDescriptionRect(self: *const App) r4os.gui.Rect {
        const rect = self.installDialogRect();
        return .{ .x = rect.x + 128, .y = rect.y + 112, .w = rect.w - 148, .h = 20 };
    }

    fn installButtonRect(self: *const App, focus: InstallFocus) r4os.gui.Rect {
        const rect = self.installDialogRect();
        return switch (focus) {
            .ok => .{ .x = rect.x + rect.w - 176, .y = rect.y + rect.h - 36, .w = 76, .h = 22 },
            .cancel => .{ .x = rect.x + rect.w - 92, .y = rect.y + rect.h - 36, .w = 76, .h = 22 },
            else => .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        };
    }
};

const action_order = [_]Action{ .start, .stop, .restart, .enable, .auto, .disable, .install, .remove, .refresh };

fn actionIndex(action: Action) usize {
    var i: usize = 0;
    while (i < action_order.len) : (i += 1) {
        if (action_order[i] == action) return i;
    }
    return 0;
}

fn actionName(action: Action) []const u8 {
    return switch (action) {
        .start => "START",
        .stop => "STOP",
        .restart => "RESTART",
        .enable => "ENABLE",
        .auto => "AUTO",
        .disable => "DISABLE",
        .install => "INSTALL",
        .remove => "REMOVE",
        .refresh => "REFRESH",
    };
}

fn serviceStateName(raw: u32) []const u8 {
    return switch (raw) {
        r4os.abi.service_state_stopped => "stopped",
        r4os.abi.service_state_starting => "starting",
        r4os.abi.service_state_running => "running",
        r4os.abi.service_state_stopping => "stopping",
        r4os.abi.service_state_failed => "failed",
        r4os.abi.service_state_disabled => "disabled",
        else => "empty",
    };
}

fn serviceStartName(raw: u32) []const u8 {
    return switch (raw) {
        r4os.abi.service_start_auto => "auto",
        r4os.abi.service_start_disabled => "disabled",
        else => "manual",
    };
}

fn serviceStateColor(raw: u32, fallback: u32) u32 {
    return switch (raw) {
        r4os.abi.service_state_running => ok_green,
        r4os.abi.service_state_failed => danger,
        else => fallback,
    };
}

fn resultName(rc: i32) []const u8 {
    return switch (rc) {
        r4os.abi.service_api_result_ok => "OK",
        r4os.abi.service_api_result_not_found => "not-found",
        r4os.abi.service_api_result_not_running => "not-running",
        r4os.abi.service_api_result_no_endpoint => "no-endpoint",
        r4os.abi.service_api_result_timeout => "timeout",
        r4os.abi.service_api_result_bad_handle => "bad-handle",
        r4os.abi.service_api_result_full => "full",
        r4os.abi.service_api_result_duplicate => "duplicate",
        r4os.abi.service_api_result_bad_path => "bad-path",
        r4os.abi.service_api_result_config_io => "config-io",
        r4os.abi.service_api_result_running => "running",
        r4os.abi.service_api_result_disabled => "disabled",
        r4os.abi.service_api_result_spawn_failed => "spawn-failed",
        r4os.abi.service_api_result_stop_failed => "stop-failed",
        else => "invalid",
    };
}

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

fn takeToken(s_raw: []const u8) ?Token {
    const s = trim(s_raw);
    if (s.len == 0) return null;
    var end: usize = 0;
    while (end < s.len and s[end] != ' ' and s[end] != '\t') : (end += 1) {}
    return .{ .token = s[0..end], .rest = trim(s[end..]) };
}

fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) : (start += 1) {}
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    return s[start..end];
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}

fn makeZ(out: []u8, value: []const u8) ?[*:0]const u8 {
    if (out.len == 0 or value.len >= out.len) return null;
    @memset(out, 0);
    if (value.len > 0) @memcpy(out[0..value.len], value);
    return @ptrCast(out.ptr);
}

fn setZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    if (out.len == 0) return;
    const len = @min(out.len - 1, value.len);
    if (len > 0) @memcpy(out[0..len], value[0..len]);
}

fn appendZ(out: []u8, value: []const u8) void {
    const current = spanZ(out).len;
    if (current >= out.len) return;
    const len = @min(out.len - current - 1, value.len);
    if (len > 0) @memcpy(out[current .. current + len], value[0..len]);
}

fn numberText(out: []u8, value: u64) void {
    @memset(out, 0);
    if (out.len == 0) return;
    var tmp: [32]u8 = undefined;
    var n = value;
    var pos: usize = tmp.len;
    if (n == 0) {
        pos -= 1;
        tmp[pos] = '0';
    } else {
        while (n > 0 and pos > 0) {
            pos -= 1;
            tmp[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
    }
    setZ(out, tmp[pos..]);
}

fn argsContain(args: []const u8, wanted: []const u8) bool {
    var rest = args;
    while (takeToken(rest)) |part| {
        if (tokenEquals(part.token, wanted)) return true;
        rest = part.rest;
    }
    return false;
}

fn tokenEquals(a: []const u8, b: []const u8) bool {
    return sameBytesIgnoreCase(trimPrefix(a), trimPrefix(b));
}

fn trimPrefix(s: []const u8) []const u8 {
    if (s.len > 0 and (s[0] == '/' or s[0] == '-')) return s[1..];
    return s;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and sameBytesIgnoreCase(s[0..prefix.len], prefix);
}

fn sameBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn sameBytesIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}
