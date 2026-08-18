pub const Lease = struct {
    active: bool = false,
    version: u64 = 0,
    target_id: usize = 0,
    focus_id: usize = 0,
    selection: usize = 0,
    caret_valid: bool = false,
    caret_x: i32 = 0,
    caret_y: i32 = 0,

    pub fn bind(
        self: *Lease,
        version: u64,
        target_id: usize,
        focus_id: usize,
        selection: usize,
        caret_valid: bool,
        caret_x: i32,
        caret_y: i32,
    ) void {
        self.* = .{
            .active = version != 0 and target_id != 0,
            .version = version,
            .target_id = target_id,
            .focus_id = focus_id,
            .selection = selection,
            .caret_valid = caret_valid,
            .caret_x = caret_x,
            .caret_y = caret_y,
        };
    }

    pub fn invalidate(self: *Lease) void {
        self.active = false;
    }

    pub fn matches(
        self: *const Lease,
        latest_version: u64,
        target_id: usize,
        focus_id: usize,
        selection: usize,
        caret_valid: bool,
        caret_x: i32,
        caret_y: i32,
    ) bool {
        return self.active and
            self.version == latest_version and
            self.target_id == target_id and
            self.focus_id == focus_id and
            self.selection == selection and
            self.caret_valid == caret_valid and
            (!caret_valid or (self.caret_x == caret_x and self.caret_y == caret_y));
    }
};
