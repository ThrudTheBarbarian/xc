// compile_check_rsc.xc — proves UXRscReader/UXRscModel COMPILE for a target whose
// stdlib has no Files.xc (wasm32, win64, arm9).  The reader's parsing is
// neutral code and must build everywhere Rocks does; only the test that reads
// a file off disk is host-only, and this keeps that distinction honest rather
// than letting those targets go silently unchecked.
#import "UXRscRead.xc"
#import "UXRscWrite.xc"
#import "UXRscModel.xc"
void main(void)
    {
    // Touch READER, WRITER and model, so none of the three can quietly stop
    // compiling for a target nobody runs.  The write is a real one: an empty
    // dialog through the whole layout pass.
    UXRscDoc* r = UXRscDoc.emptyDialog();
    if (r.treeCount() != (i32)1)
        {
        return;
        }
    UXData* out = UXRscWriter.write(r);
    if (out == (UXData*)0 || out.length() < (i32)36)
        {
        return;
        }
    UXRscDoc* back = UXRscReader.read(out.bytes(), out.length());
    if (back == (UXRscDoc*)0)
        {
        return;
        }
    }
