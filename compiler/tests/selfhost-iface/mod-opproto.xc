// The MODULE half for operator requirements: a protocol whose methods are
// operators, `+`, `**` above `*` and grouping from the right, and `|p|`. The
// requirements and the precedence travel in the .xtc.iface, so use-opproto.xc
// parses `a ** b` and `|a|` as this module does and resolves them through the
// protocol.
protocol Num
    {
    Num* plus(Num* o) :operator(self + o);
    Num* raise(Num* e) :operator(self ** e) :precedence(above *, right);
    Num* times(Num* o) :operator(self * o);
    i32 size() :operator(|self|);
    i32 value();
    }
