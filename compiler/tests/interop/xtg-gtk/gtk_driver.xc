#import "Stdio.xc"
#import <gtkshim>

i32 xt_init(void);
pointer xt_window(void);
pointer xt_button(pointer label);
pointer xt_connect(pointer w, pointer sig, pointer cb, pointer data);
void xt_emit_clicked(pointer w);

// neutral layer
class XGView
    {
    void clicked(void)
        {
        }
    } class MyView : XGView
    {
    void clicked(void)
        {
        Stdio.printf("clicked!\n");
        }
    }

    // GTK driver callback: g_signal_connect user_data = the reverse map.
    void on_clicked(pointer widget, pointer user_data)
    {
    XGView* v = (XGView*)user_data;
    v.clicked();
    }

void main(void)
    {
    Stdio.printf("init=%d\n", xt_init());
    pointer win = xt_window();
    Stdio.printf("window=%d\n", (i32)(win != (pointer)0));
    pointer btn = xt_button((pointer) "Hi");
    Stdio.printf("button=%d\n", (i32)(btn != (pointer)0));

    MyView* view = new MyView();
    xt_connect(btn, (pointer) "clicked", &on_clicked, (pointer)view); // reverse map via user_data
    xt_emit_clicked(btn);                                             // GTK invokes on_clicked
    Stdio.printf("done\n");
    }
