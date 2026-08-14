/* The whole point of this file: linked FIRST, containing nothing but
 * this jump, so the seglist's first byte is executable code. String
 * literals in the main TU land in .text ahead of its functions, which
 * is why the entry cannot live there. */
extern long handler_main(void);
long aminfs_entry(void) { return handler_main(); }
