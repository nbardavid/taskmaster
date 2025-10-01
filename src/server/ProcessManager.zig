const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const Thread = std.Thread;
const posix = std.posix;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const HashMap = std.StringArrayHashMapUnmanaged;

const common = @import("common");
const Config = common.Config;
const Logger = common.Logger;

const Process = @import("Process.zig");
const ExitCode = Process.ExitCode;
const Child = @import("Child.zig");

pub const ProcessManager = @This();

gpa: mem.Allocator,
config: Config,
live: HashMap(*Process),
live_pid: AutoArrayHashMapUnmanaged(posix.pid_t, ProcessChild),
thread: ?Thread,
stopping: std.atomic.Value(bool) = .{ .raw = false },
new_cmd: std.atomic.Value(bool) = .{ .raw = false },
cmd: common.Command,
cmd_payload: [256]u8,
logger: *Logger,
mailbox: ?*@import("Mailbox.zig") = null,

pub const ProcessChild = struct {
    parent: *Process,
    index: usize,
};

pub fn init(gpa: mem.Allocator, config_file_path: []const u8, logger: *Logger) ProcessManager {
    return .{
        .gpa = gpa,
        .config = Config.init(config_file_path),
        .live = HashMap(*Process).empty,
        .live_pid = AutoArrayHashMapUnmanaged(posix.pid_t, ProcessChild).empty,
        .thread = null,
        .stopping = .{ .raw = false },
        .new_cmd = .{ .raw = false },
        .cmd = undefined,
        .cmd_payload = undefined,
        .logger = logger,
    };
}

pub fn setMailbox(self: *ProcessManager, mailbox: *@import("Mailbox.zig")) void {
    self.mailbox = mailbox;
}

pub fn deinit(self: *ProcessManager) void {
    self.stopping.store(true, .release);

    if (self.thread) |t| {
        t.join();
        self.thread = null;
    }

    self.shutdown() catch {};
    self.config.deinit();

    var it = self.live.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.destroy(self.gpa);
    }

    self.live.deinit(self.gpa);
    self.live_pid.deinit(self.gpa);
}

pub fn start(self: *ProcessManager) !void {
    const thread = try Thread.spawn(.{}, ProcessManager.mainLoop, .{self});
    self.thread = thread;
}

fn sendResponse(self: *ProcessManager, status: common.ResponseStatus, payload: []const u8) void {
    if (self.mailbox) |mb| {
        const response = common.Response{
            .status = status,
            .payload_len = @intCast(@min(payload.len, std.math.maxInt(u16))),
        };
        mb.sendResponse(response, payload);
    } else {
        self.logger.warn("cannot send response: mailbox not set", .{});
    }
}

fn checkForNewCommand(self: *ProcessManager, out_cmd: *common.Command, out_cmd_payload: *[256]u8) bool {
    if (self.new_cmd.load(.acquire)) {
        out_cmd.* = self.cmd;
        const payload_len = self.cmd.payload_len;
        @memcpy(out_cmd_payload[0..payload_len], self.cmd_payload[0..payload_len]);
        self.new_cmd.store(false, .monotonic);
        return true;
    }
    return false;
}

fn loadConfig(self: *ProcessManager) !Config.ParsedResult {
    try self.config.open();
    return try self.config.parseLeaky(self.gpa);
}

fn stageNewConfig(self: *ProcessManager, parsed: *Config.ParsedResult) !HashMap(*Process) {
    var result_map = parsed.getResultMap();
    const total_processes: usize = result_map.map.count();

    if (total_processes == 0) {
        return HashMap(*Process).empty;
    }

    var list: ArrayListUnmanaged(*Process) = .empty;
    defer list.deinit(self.gpa);
    errdefer {
        for (list.items) |process| process.destroy(self.gpa);
    }
    try list.ensureUnusedCapacity(self.gpa, total_processes);

    for (0..total_processes) |_| {
        const proc = try Process.create(self.gpa, self.logger);
        list.appendAssumeCapacity(proc);
    }

    var it = result_map.map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        try list.items[i].configure(entry.key_ptr.*, entry.value_ptr);
    }

    var new_staged: HashMap(*Process) = .empty;
    errdefer {
        if (new_staged.count() > 0) {
            var cleanup_it = new_staged.iterator();
            while (cleanup_it.next()) |entry| {
                entry.value_ptr.*.destroy(self.gpa);
            }
        }
        new_staged.deinit(self.gpa);
    }

    try new_staged.ensureUnusedCapacity(self.gpa, total_processes);
    for (list.items) |process| {
        new_staged.putAssumeCapacity(process.config.name, process);
    }

    return new_staged;
}

fn cleanupStagedConfig(self: *ProcessManager, staged: *HashMap(*Process)) void {
    if (staged.count() == 0) {
        staged.deinit(self.gpa);
        staged.* = HashMap(*Process).empty;
        return;
    }

    var it = staged.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.destroy(self.gpa);
    }
    staged.deinit(self.gpa);
    staged.* = HashMap(*Process).empty;
}

fn commitStagedConfig(self: *ProcessManager, staged: *HashMap(*Process)) !HashMap(*Process) {
    var new_live: HashMap(*Process) = .empty;
    errdefer new_live.deinit(self.gpa);
    try new_live.ensureUnusedCapacity(self.gpa, staged.count());

    var it = staged.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const staged_proc = entry.value_ptr.*;

        if (self.live.get(name)) |old_proc| {
            const staged_hash = staged_proc.hash();
            const old_hash = old_proc.hash();

            if (staged_hash == old_hash) {
                staged_proc.destroy(self.gpa);
                // Use old_proc's name since we just freed staged_proc
                try new_live.put(self.gpa, old_proc.config.name, old_proc);
                if (old_proc.config.conf.autostart) {
                    try self.startProcess(old_proc);
                }
            } else {
                try self.stopProcess(old_proc);
                // Use staged_proc's name since it's still alive
                try new_live.put(self.gpa, staged_proc.config.name, staged_proc);
                if (staged_proc.config.conf.autostart)
                    try self.startProcess(staged_proc);
            }
        } else {
            // Use staged_proc's name since it's still alive
            try new_live.put(self.gpa, staged_proc.config.name, staged_proc);
            if (staged_proc.config.conf.autostart)
                try self.startProcess(staged_proc);
        }
    }

    var it_old = self.live.iterator();
    while (it_old.next()) |entry| {
        const name = entry.key_ptr.*;
        const old_proc = entry.value_ptr.*;
        if (!new_live.contains(name)) {
            try self.stopProcess(old_proc);
            old_proc.destroy(self.gpa);
        }
    }

    var it_staged = staged.iterator();
    while (it_staged.next()) |entry| {
        const name = entry.key_ptr.*;
        const staged_proc = entry.value_ptr.*;
        if (!new_live.contains(name)) {
            staged_proc.destroy(self.gpa);
        }
    }

    self.live.deinit(self.gpa);
    staged.deinit(self.gpa);
    return new_live;
}

fn replaceProcess(self: *ProcessManager, old_proc: *Process, new_proc: *Process) !void {
    try self.stopProcess(old_proc);
    old_proc.destroy(self.gpa);

    if (new_proc.config.conf.autostart) {
        try self.startProcess(new_proc);
    }
}

fn stopProcess(self: *ProcessManager, proc: *Process) !void {
    for (proc.instances) |*inst| {
        if (inst.pid) |pid| {
            try inst.stop(@intFromEnum(proc.config.conf.stopsignal), proc.config.conf.stoptime * 1000);
            self.removeLivePid(pid);
        }
    }
}

fn startProcess(self: *ProcessManager, proc: *Process) !void {
    const arena = proc.arena.allocator();
    for (proc.instances, 0..) |*inst, i| {
        if (inst.status == .stopped or inst.status == .exited or inst.status == .fatal) {
            self.logger.info("starting process {s}[{d}] (current status: {s})", .{ proc.config.name, i, @tagName(inst.status) });
            try inst.start(&proc.config, arena);
            try self.updateLivePid(inst, proc, i);
        } else {
            self.logger.debug("skipping start of process {s}[{d}] - already in status: {s}", .{ proc.config.name, i, @tagName(inst.status) });
        }
    }
}

fn restartProcess(self: *ProcessManager, proc: *Process) !void {
    try self.stopProcess(proc);
    try self.startProcess(proc);
}

fn updateLivePid(self: *ProcessManager, child: *const Child, proc: *Process, index: usize) !void {
    if (child.pid) |pid| {
        try self.live_pid.put(self.gpa, pid, .{ .parent = proc, .index = index });
        self.logger.debug("updated live PID tracking: pid={d} for process {s}[{d}]", .{ pid, proc.config.name, index });
    } else {
        self.logger.warn("attempted to update live PID tracking but child has no PID for process {s}[{d}]", .{ proc.config.name, index });
    }
}

fn removeLivePid(self: *ProcessManager, pid: posix.pid_t) void {
    if (self.live_pid.swapRemove(pid)) {
        self.logger.debug("removed PID {d} from live tracking", .{pid});
    } else {
        self.logger.warn("attempted to remove PID {d} but it was not being tracked", .{pid});
    }
}

fn manageProcess(self: *ProcessManager, proc: *Process) !void {
    const now: u64 = @intCast(std.time.milliTimestamp());

    for (proc.instances, 0..) |*child, i| {
        if (child.pid) |pid| {
            if (child.poll()) |result| {
                if (result != null) {
                    self.removeLivePid(pid);
                    self.logger.info("detected exit of process {s}[{d}] pid={d}", .{ proc.config.name, i, pid });
                }
            } else |err| {
                self.logger.err("failed to poll process {s}[{d}] pid={d}: {}", .{ proc.config.name, i, pid, err });

                child.finalizeExit(null, null);
                self.removeLivePid(pid);
            }
        } else if (child.status == .running) {
            self.logger.warn("process {s}[{d}] has status=running but no PID, marking as exited", .{ proc.config.name, i });
            child.status = .exited;
        }

        switch (child.status) {
            .starting => {
                if ((now - child.last_start_time) >= (proc.config.conf.starttime * 1000)) {
                    if (child.pid) |pid| {
                        if (child.status != .starting) {
                            continue;
                        }

                        if (posix.kill(pid, 0)) |_| {
                            child.status = .running;
                            child.retries = 0; // Reset retries on successful start
                            try self.updateLivePid(child, proc, i);
                            self.logger.info("process {s}[{d}] marked as successfully started (retries reset)", .{ proc.config.name, i });
                        } else |err| switch (err) {
                            error.ProcessNotFound => {
                                child.status = .exited;
                                self.removeLivePid(pid);
                                self.logger.warn("process {s}[{d}] died during startup period", .{ proc.config.name, i });
                            },
                            else => {
                                self.logger.debug("could not verify process {s}[{d}] status: {}", .{ proc.config.name, i, err });
                            },
                        }
                    } else {
                        child.status = .fatal;
                        self.logger.err("process {s}[{d}] has no PID after startup period", .{ proc.config.name, i });
                    }
                }
            },
            .backoff => {
                if (child.backoff_until) |until| {
                    if (now >= until) {
                        const should_restart = switch (proc.config.conf.autorestart) {
                            .always => true,
                            .unexpected => if (child.exit_code) |code| !proc.isExpectedExitCode(code) else true,
                            .never => false,
                        };

                        child.backoff_until = null;

                        if (!should_restart) {
                            child.status = .stopped;
                            self.logger.info("process {s}[{d}] stopped after backoff (no restart needed)", .{ proc.config.name, i });
                        } else if (child.retries < proc.config.conf.startretries) {
                            self.logger.info("process {s}[{d}] retrying after backoff ({d}/{d})", .{ proc.config.name, i, child.retries + 1, proc.config.conf.startretries });
                            try child.restart(&proc.config, proc.arena.allocator());
                            try self.updateLivePid(child, proc, i);
                        } else {
                            child.status = .fatal;
                            self.logger.err("process {s}[{d}] exceeded retry limit after backoff", .{ proc.config.name, i });
                        }
                    }
                }
            },
            .exited => {
                const should_restart = switch (proc.config.conf.autorestart) {
                    .always => true,
                    .unexpected => if (child.exit_code) |code| !proc.isExpectedExitCode(code) else true,
                    .never => false,
                };

                if (!should_restart) {
                    // Process exited expectedly, don't restart
                    child.status = .stopped;
                    self.logger.info("process {s}[{d}] stopped (expected exit)", .{ proc.config.name, i });
                } else {
                    // Process should restart - check if we haven't exceeded retry limit
                    // Note: restart() will increment retries only if it was a failed start
                    const was_successful_start = (now - child.last_start_time) >= (proc.config.conf.starttime * 1000);

                    if (was_successful_start) {
                        // Process ran successfully, reset retry counter before restarting
                        child.retries = 0;
                        self.logger.info("process {s}[{d}] exited after successful run, restarting (retries reset)", .{ proc.config.name, i });
                        try child.restart(&proc.config, proc.arena.allocator());
                        try self.updateLivePid(child, proc, i);
                    } else if (child.retries < proc.config.conf.startretries) {
                        // Failed start but still have retries left
                        self.logger.info("process {s}[{d}] failed to start, retrying ({d}/{d})", .{ proc.config.name, i, child.retries + 1, proc.config.conf.startretries });
                        try child.restart(&proc.config, proc.arena.allocator());
                        try self.updateLivePid(child, proc, i);
                    } else {
                        // Exceeded retry limit
                        child.status = .fatal;
                        self.logger.err("process {s}[{d}] entered fatal state after {d} failed start attempts", .{ proc.config.name, i, child.retries });
                    }
                }
            },
            .running => {},
            .stopping => {},
            .stopped => {},
            .fatal => {},
        }
    }
}

fn monitorProcesses(self: *ProcessManager) !void {
    var it = self.live.iterator();
    while (it.next()) |entry| {
        try self.manageProcess(entry.value_ptr.*);
    }
}

fn mainLoop(self: *ProcessManager) !void {
    const logger = self.logger;
    var fatal_error: anyerror = undefined;
    var current_parsed_result: Config.ParsedResult = .empty;
    defer current_parsed_result.deinit();
    var new_config_staging: HashMap(*Process) = .empty;
    var staging_initialized: bool = false;
    errdefer {
        if (staging_initialized) {
            self.cleanupStagedConfig(&new_config_staging);
        }
    }
    var local_command: common.Command = undefined;
    var local_command_payload: [256]u8 = undefined;

    state: switch (Status.process_manager_needs_to_load_the_inial_config) {
        .process_manager_needs_to_load_the_inial_config => {
            logger.info("state=LOAD_INITIAL_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.loadConfig()) |result| {
                logger.info("config loaded successfully", .{});
                current_parsed_result = result;
                current_parsed_result.valid = true;
                continue :state .process_manager_needs_to_stage_the_new_config;
            } else |err| {
                logger.err("config load failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_load_config;
            }
        },

        .process_manager_needs_to_load_a_config => {
            logger.info("state=LOAD_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            current_parsed_result.deinit();
            current_parsed_result = .empty;
            current_parsed_result.valid = false;

            if (self.config.parseLeaky(self.gpa)) |result| {
                logger.info("config loaded successfully", .{});
                current_parsed_result = result;
                current_parsed_result.valid = true;
                continue :state .process_manager_needs_to_stage_the_new_config;
            } else |err| {
                logger.err("config load failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_load_config;
            }
        },

        .process_manager_needs_to_stage_the_new_config => {
            logger.info("state=STAGE_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.stageNewConfig(&current_parsed_result)) |new_config| {
                logger.info("staged new config successfully ({} processes)", .{new_config.count()});
                new_config_staging = new_config;
                staging_initialized = true;
                continue :state .process_manager_needs_to_commit_the_new_config;
            } else |err| {
                logger.err("staging config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_stage_config;
            }
        },

        .process_manager_needs_to_commit_the_new_config => {
            logger.info("state=COMMIT_NEW_CONFIG", .{});
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.commitStagedConfig(&new_config_staging)) |new_live| {
                logger.info("committed new config ({} live processes)", .{new_live.count()});
                self.live = new_live;
                staging_initialized = false;
                continue :state .process_manager_needs_to_apply_the_new_config;
            } else |err| {
                logger.err("commit config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_commit_config;
            }
        },

        .process_manager_needs_to_apply_the_new_config => {
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.monitorProcesses()) {
                continue :state .process_manager_needs_to_monitor_processes;
            } else |err| {
                logger.err("apply config failed: {}", .{err});
                fatal_error = err;
                continue :state .process_manager_failed_to_apply_config;
            }
        },

        .process_manager_needs_to_monitor_processes => {
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;

            if (self.monitorProcesses()) {
                continue :state .process_manager_needs_to_check_for_new_command;
            } else |err| {
                fatal_error = err;
                continue :state .process_manager_encountered_fatal_error;
            }
        },

        .process_manager_needs_to_check_for_new_command => {
            if (self.stopping.load(.acquire)) continue :state .process_manager_needs_to_shutdown;
            if (self.checkForNewCommand(&local_command, &local_command_payload)) {
                logger.info("state=PM_NEEDS_TO_WAIT_FOR_COMMANDS ", .{});
                continue :state .process_manager_needs_to_route_the_new_command;
            } else {
                Thread.sleep(std.time.ns_per_us * 100); // 100 microseconds
                continue :state .process_manager_needs_to_monitor_processes;
            }
        },

        .process_manager_needs_to_route_the_new_command => {
            logger.info("state=PM_NEEDS_TO_EXEC_COMMAND", .{});
            switch (local_command.cmd) {
                .status => continue :state .process_manager_exec_status,
                .start => continue :state .process_manager_exec_start,
                .stop => continue :state .process_manager_exec_stop,
                .restart => continue :state .process_manager_exec_restart,
                .reload => continue :state .process_manager_exec_reload,
                .dump => continue :state .process_manager_exec_dump,
                .quit => continue :state .process_manager_exec_quit,
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_status => {
            const name = local_command_payload[0..local_command.payload_len];

            if (name.len == 0) {
                self.sendResponse(.err, "Error: program name required\n");
                logger.warn("status command requires program name", .{});
                continue :state .process_manager_needs_to_check_for_new_command;
            }

            if (self.live.get(name)) |proc| {
                var builder = common.ResponseBuilder.init(self.gpa);
                defer builder.deinit();

                if (self.buildProcessStatus(proc, &builder)) {
                    const payload = builder.getPayload();
                    self.sendResponse(.success, payload);
                    logger.info("sent status for {s}", .{name});
                } else |err| {
                    logger.err("failed to build status for {s}: {}", .{ name, err });
                    self.sendResponse(.err, "Error: failed to build status\n");
                }
            } else {
                var builder = common.ResponseBuilder.init(self.gpa);
                defer builder.deinit();
                builder.appendFmt("Error: program '{s}' not found\n", .{name}) catch {};
                const payload = builder.getPayload();
                self.sendResponse(.not_found, payload);
                logger.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_start => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.startProcess(proc)) |_| {
                    var builder = common.ResponseBuilder.init(self.gpa);
                    defer builder.deinit();
                    builder.appendFmt("Started process '{s}'\n", .{name}) catch {};
                    self.sendResponse(.success, builder.getPayload());
                    logger.info("started {s}", .{name});
                } else |err| {
                    var builder = common.ResponseBuilder.init(self.gpa);
                    defer builder.deinit();
                    builder.appendFmt("Error: failed to start '{s}': {}\n", .{ name, err }) catch {};
                    self.sendResponse(.err, builder.getPayload());
                    logger.err("failed to start {s}: {}", .{ name, err });
                }
            } else {
                var builder = common.ResponseBuilder.init(self.gpa);
                defer builder.deinit();
                builder.appendFmt("Error: program '{s}' not found\n", .{name}) catch {};
                self.sendResponse(.not_found, builder.getPayload());
                logger.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_stop => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.stopProcess(proc)) |_| {
                    var builder = common.ResponseBuilder.init(self.gpa);
                    defer builder.deinit();
                    builder.appendFmt("Stopped process '{s}'\n", .{name}) catch {};
                    self.sendResponse(.success, builder.getPayload());
                    logger.info("stopped {s}", .{name});
                } else |err| {
                    var builder = common.ResponseBuilder.init(self.gpa);
                    defer builder.deinit();
                    builder.appendFmt("Error: failed to stop '{s}': {}\n", .{ name, err }) catch {};
                    self.sendResponse(.err, builder.getPayload());
                    logger.err("failed to stop {s}: {}", .{ name, err });
                }
            } else {
                var builder = common.ResponseBuilder.init(self.gpa);
                defer builder.deinit();
                builder.appendFmt("Error: program '{s}' not found\n", .{name}) catch {};
                self.sendResponse(.not_found, builder.getPayload());
                logger.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_restart => {
            const name = local_command_payload[0..local_command.payload_len];
            if (self.live.get(name)) |proc| {
                if (self.restartProcess(proc)) |_| {
                    var builder = common.ResponseBuilder.init(self.gpa);
                    defer builder.deinit();
                    builder.appendFmt("Restarted process '{s}'\n", .{name}) catch {};
                    self.sendResponse(.success, builder.getPayload());
                    logger.info("restarted {s}", .{name});
                } else |err| {
                    var builder = common.ResponseBuilder.init(self.gpa);
                    defer builder.deinit();
                    builder.appendFmt("Error: failed to restart '{s}': {}\n", .{ name, err }) catch {};
                    self.sendResponse(.err, builder.getPayload());
                    logger.err("failed to restart {s}: {}", .{ name, err });
                }
            } else {
                var builder = common.ResponseBuilder.init(self.gpa);
                defer builder.deinit();
                builder.appendFmt("Error: program '{s}' not found\n", .{name}) catch {};
                self.sendResponse(.not_found, builder.getPayload());
                logger.warn("no process named {s}", .{name});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_reload => {
            logger.info("reloading config…", .{});
            self.sendResponse(.success, "Reloading configuration...\n");
            continue :state .process_manager_reset_config_file_seek_position;
        },

        .process_manager_reset_config_file_seek_position => {
            logger.info("reloading content of config file", .{});
            if (self.config.reload()) {
                continue :state .process_manager_needs_to_load_a_config;
            } else |err| {
                logger.err("failed to reload config {}", .{err});
                fatal_error = err;
                continue :state .process_manager_encountered_fatal_error;
            }
        },

        .process_manager_exec_dump => {
            var builder = common.ResponseBuilder.init(self.gpa);
            defer builder.deinit();

            var it = self.live.iterator();
            while (it.next()) |entry| {
                const proc = entry.value_ptr.*;
                if (self.buildProcessStatus(proc, &builder)) {
                    // Successfully added to builder
                } else |err| {
                    logger.err("failed to build status for {s}: {}", .{ proc.config.name, err });
                }
            }

            const payload = builder.getPayload();
            if (payload.len > 0) {
                self.sendResponse(.success, payload);
                logger.info("sent dump for all processes", .{});
            } else {
                self.sendResponse(.success, "No processes configured\n");
                logger.info("no processes to dump", .{});
            }
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_exec_quit => {
            logger.info("received quit", .{});
            self.sendResponse(.success, "Shutting down server...\n");
            Thread.sleep(std.time.ns_per_ms * 100);
            self.stopping.store(true, .release);
            continue :state .process_manager_needs_to_shutdown;
        },

        .process_manager_failed_to_load_config => {
            logger.err("failed to load config: {}", .{fatal_error});
            logger.warn("waiting for valid config - entering monitoring loop with no processes", .{});
            continue :state .process_manager_needs_to_check_for_new_command;
        },

        .process_manager_failed_to_stage_config => {
            logger.err("failed to stage config: {}", .{fatal_error});
            logger.warn("maintaining previous configuration and continuing monitoring", .{});
            continue :state .process_manager_needs_to_monitor_processes;
        },

        .process_manager_failed_to_commit_config => {
            logger.err("failed to commit config: {}", .{fatal_error});
            logger.warn("maintaining previous configuration and continuing monitoring", .{});
            continue :state .process_manager_needs_to_monitor_processes;
        },

        .process_manager_failed_to_apply_config => {
            logger.err("failed to apply config: {}", .{fatal_error});
            continue :state .process_manager_encountered_fatal_error;
        },

        .process_manager_encountered_fatal_error => {
            logger.err("fatal error in process manager: {}", .{fatal_error});
            return fatal_error;
        },

        .process_manager_needs_to_shutdown => {
            logger.info("process manager loop shutting down", .{});
            return;
        },
    }
}

const Status = enum {
    process_manager_encountered_fatal_error,
    process_manager_exec_dump,
    process_manager_exec_quit,
    process_manager_exec_reload,
    process_manager_exec_restart,
    process_manager_exec_start,
    process_manager_exec_status,
    process_manager_exec_stop,
    process_manager_failed_to_apply_config,
    process_manager_failed_to_commit_config,
    process_manager_failed_to_load_config,
    process_manager_failed_to_stage_config,
    process_manager_needs_to_apply_the_new_config,
    process_manager_needs_to_check_for_new_command,
    process_manager_needs_to_commit_the_new_config,
    process_manager_needs_to_load_a_config,
    process_manager_needs_to_load_the_inial_config,
    process_manager_needs_to_monitor_processes,
    process_manager_needs_to_route_the_new_command,
    process_manager_needs_to_shutdown,
    process_manager_needs_to_stage_the_new_config,
    process_manager_reset_config_file_seek_position,
};

fn shutdown(self: *ProcessManager) !void {
    var it = self.live.iterator();
    while (it.next()) |entry| {
        try self.stopProcess(entry.value_ptr.*);
    }
}

fn buildProcessStatus(self: *ProcessManager, proc: *Process, builder: *common.ResponseBuilder) !void {
    const status = proc.currentStatus();
    const status_symbol = switch (status) {
        .running => "●",
        .stopped, .exited => "○",
        .fatal => "✗",
        .backoff => "◐",
        .starting => "◐",
        .stopping => "◯",
        else => "◯",
    };

    const status_color = switch (status) {
        .running => "\x1b[32m",
        .stopped, .exited => "\x1b[37m",
        .fatal => "\x1b[31m",
        .backoff, .starting => "\x1b[33m",
        .stopping => "\x1b[35m",
        else => "\x1b[37m",
    };

    const reset_color = "\x1b[0m";

    try builder.appendFmt("{s}{s}{s} {s} - {s}\n", .{ status_color, status_symbol, reset_color, proc.config.name, proc.config.conf.cmd });

    try builder.appendFmt("     Loaded: loaded (command: {s}, numprocs: {d})\n", .{ proc.config.conf.cmd, proc.config.conf.numprocs });

    const status_str = switch (status) {
        .running => "active (running)",
        .stopped => "inactive (dead)",
        .exited => "inactive (exited)",
        .fatal => "failed (fatal)",
        .backoff => "activating (backoff)",
        .starting => "activating (starting)",
        .stopping => "deactivating (stopping)",
        else => "unknown",
    };

    try builder.appendFmt("     Active: {s}{s}{s}\n", .{ status_color, status_str, reset_color });

    var running_count: usize = 0;
    var starting_count: usize = 0;
    var stopping_count: usize = 0;
    var backoff_count: usize = 0;
    var fatal_count: usize = 0;
    var main_pid: ?std.posix.pid_t = null;

    for (proc.instances, 0..) |*inst, i| {
        self.logger.debug("  Instance[{d}]: status={s}, pid={?d}", .{ i, @tagName(inst.status), inst.pid });
        switch (inst.status) {
            .running => {
                running_count += 1;
                if (main_pid == null) main_pid = inst.pid;
            },
            .starting => starting_count += 1,
            .stopping => stopping_count += 1,
            .backoff => backoff_count += 1,
            .fatal => fatal_count += 1,
            else => {},
        }
    }

    if (main_pid) |pid| {
        try builder.appendFmt("   Main PID: {d}\n", .{pid});
    }

    try builder.appendFmt("      Tasks: {d} running, {d} starting, {d} stopping, {d} backoff, {d} fatal (total: {d})\n", .{ running_count, starting_count, stopping_count, backoff_count, fatal_count, proc.instances.len });

    try builder.append("\n");
}
