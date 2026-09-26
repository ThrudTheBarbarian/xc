//xtc-flags: target=xt6502, expect=sema-error
// coder_xt6502_refused.xc — Coder does not exist on xt6502.
//
// Archiving is not available there, and Object keeps its three methods with
// no Codable slots, so importing Coder.xc must stop the build with an error
// that says so rather than compile against a class that is not there.
#import "Stdio.xc"
#import "Coder.xc"

void main(void)
{
    Stdio.printf("%s\n", Coder.archiveJSON(String.withCString("x")).cString());
}
