// A shape has one precedence in a program, whether a protocol or a class
// gives it.
// xtc: error "operator '**' has the precedence 'above *, right' in 'Power.pow' and 'above +' in 'Int.pow': an operator has one precedence; give both the same ':precedence', or leave it off one of them"
protocol Power
    {
    Power* pow(Power* e) :operator(self ** e) :precedence(above *, right);
    }

class Int <Power>
    {
    i32 v;
    Power* pow(Power* e) :operator(self ** e) :precedence(above +) { return e; }
    }

i32 main(void) { return 0; }
