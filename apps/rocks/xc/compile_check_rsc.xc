// compile_check_rsc.xc — proves RKRsc/RKModel COMPILE for a target whose
// stdlib has no Files.xc (wasm32, win64, arm9).  The reader's parsing is
// neutral code and must build everywhere Rocks does; only the test that reads
// a file off disk is host-only, and this keeps that distinction honest rather
// than letting those targets go silently unchecked.
#import "RKRsc.xc"
#import "RKRscWrite.xc"
#import "RKModel.xc"
void main(void)
    {
    // Touch READER, WRITER and model, so none of the three can quietly stop
    // compiling for a target nobody runs.  The write is a real one: an empty
    // dialog through the whole layout pass.
    RKResource* r = RKResource.emptyDialog();
    if (r.treeCount() != (i32)1)
        {
        return;
        }
    UXData* out = RKRscWrite.write(r);
    if (out == (UXData*)0 || out.length() < (i32)36)
        {
        return;
        }
    RKResource* back = RKRsc.read(out.bytes(), out.length());
    if (back == (RKResource*)0)
        {
        return;
        }
    }
