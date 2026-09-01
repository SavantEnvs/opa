// Disable LeakSanitizer at build time (SPEC §6.2 item 15); ASan stays fully on.
extern "C" int __lsan_is_turned_off() { return 1; }
