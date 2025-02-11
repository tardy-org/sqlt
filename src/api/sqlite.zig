const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"sqlt/sqlite");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Sqlite = struct {
    db: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Sqlite {
        var sqlite: ?*c.sqlite3 = null;
        errdefer {
            if (sqlite) |sql| _ = c.sqlite3_close(sql);
        }

        const rc = c.sqlite3_open(path.ptr, &sqlite);
        if (rc != c.SQLITE_OK) {
            log.err(
                "sqlite3 open failed: {s}",
                .{std.mem.span(c.sqlite3_errmsg(sqlite))},
            );
            return error.FailedOpen;
        }

        return .{ .db = sqlite.? };
    }

    pub fn close(self: Sqlite) void {
        _ = c.sqlite3_close(self.db);
    }

    fn bind_param(
        comptime T: type,
        stmt: *c.sqlite3_stmt,
        value: anytype,
        index: c_int,
    ) c_int {
        return switch (@typeInfo(T)) {
            .Int => |info| if (info.bits < 32)
                c.sqlite3_bind_int(stmt, index, @intCast(value))
            else
                c.sqlite3_bind_int64(stmt, index, @intCast(value)),
            .Float => c.sqlite3_bind_double(stmt, index, @floatCast(value)),
            .Optional => |info| if (value) |v|
                bind_param(info.child, stmt, v, index)
            else
                c.sqlite3_bind_null(stmt, index),
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .Slice => switch (ptr_info.child) {
                    u8 => c.sqlite3_bind_text(
                        stmt,
                        index,
                        value.ptr,
                        @intCast(value.len),
                        c.SQLITE_STATIC,
                    ),
                    else => @compileError("Unsupported slice type: " ++ @typeName(T)),
                },
                .One => bind_param(ptr_info.child, stmt, value, index),
                else => @compileError("Unsupported pointer type: " ++ @typeName(T)),
            },
            .Array => |info| switch (info.child) {
                u8 => c.sqlite3_bind_text(
                    stmt,
                    index,
                    value.ptr,
                    @intCast(value.len),
                    c.SQLITE_STATIC,
                ),
                else => @compileError("Unsupported array type: " ++ @typeName(T)),
            },
            else => switch (T) {
                []const u8, [:0]const u8, *[]const u8 => c.sqlite3_bind_text(
                    stmt,
                    index,
                    value.ptr,
                    @intCast(value.len),
                    c.SQLITE_STATIC,
                ),
                bool => c.sqlite3_bind_int(stmt, index, @intFromBool(value)),
                else => @compileError("Unsupported type for sqlite binding: " ++ @typeName(T)),
            },
        };
    }

    fn bind_params(stmt: *c.sqlite3_stmt, params: anytype) !void {
        const params_info = @typeInfo(@TypeOf(params));
        if (params_info != .Struct) @compileError("params must be a tuple or struct");

        inline for (params_info.Struct.fields, 0..) |field, i| {
            const index: c_int = @intCast(i + 1);
            const value = @field(params, field.name);
            const rc = bind_param(field.type, stmt, value, index);
            if (rc != c.SQLITE_OK) return error.BindError;
        }
    }

    pub fn execute(self: Sqlite, comptime sql: []const u8, params: anytype) !void {
        var stmt: ?*c.sqlite3_stmt = null;

        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            log.err("sqlite3 prepare failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.FailedPrepare;
        }
        defer _ = c.sqlite3_finalize(stmt);

        try bind_params(stmt.?, params);

        const step_rc = c.sqlite3_step(stmt.?);
        if (step_rc != c.SQLITE_DONE) {
            log.err("sqlite3 step failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return error.StepError;
        }
    }
};
