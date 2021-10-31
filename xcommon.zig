
pub fn toNewline(start: [*]u8, cursor_arg: [*]u8) ?[*]u8 {
    var cursor = cursor_arg;
    while (true) {
        if (@ptrToInt(cursor) <= @ptrToInt(start))
            return null;
        cursor -= 1;
        if (cursor[0] == '\n')
            return cursor;
    }
}
