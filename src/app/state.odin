package app 

context_t :: struct {
    isLogged         : bool,
    logInfo          : log_system_t,
    csv_files        : [dynamic]string,
    csv_documents    : [dynamic]CSV_Document,
    current_data_col : int,
    highlighted_row  : int,
}

context_t_default :: proc() -> context_t {
    return context_t {
        isLogged = false,
        logInfo  = log_system_t_default(),
        csv_files = make([dynamic]string, 0, 16),
        csv_documents = make([dynamic]CSV_Document, 0, 16),
    }
}

context_select_csv_row :: proc(self : ^context_t, idx : int) {
    self.highlighted_row = idx
} 

context_select_csv_col :: proc(self : ^context_t, idx : int) {
    self.current_data_col = idx
}
