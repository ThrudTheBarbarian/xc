/* GTK4 C ABI, hand-declared (no -dev headers on this host). Wraps the few
   entry points the spike needs; a real xtc GTK binding would #import these. */
typedef void* gp;
extern int gtk_init_check(void);
extern gp gtk_window_new(void);
extern gp gtk_button_new_with_label(const char*);
extern unsigned long g_signal_connect_data(gp, const char*, void*, gp, void*, int);
extern void g_signal_emit_by_name(gp, const char*, ...);

int xt_init(void)
    {
    return gtk_init_check();
    }
gp xt_window(void)
    {
    return gtk_window_new();
    }
gp xt_button(const char* l)
    {
    return gtk_button_new_with_label(l);
    }
unsigned long xt_connect(gp w, const char* sig, void* cb, gp data)
    {
    return g_signal_connect_data(w, sig, cb, data, 0, 0);
    }
void xt_emit_clicked(gp w)
    {
    g_signal_emit_by_name(w, "clicked");
    }
