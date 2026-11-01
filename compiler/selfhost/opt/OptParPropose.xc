// OptParPropose.xc — par-propose's report: the loops it would wrap, and why the others stay.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptOutline>

    class Opt (ParPropose)
    {

    final void parProposeReport(IRModule* m)
        {
        // Every program: --par-auto imports the runtime where a loop needs it.
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.blocks().count() == (u32)0)
                continue;
            // A written par block's body (ParImpl$<n>$…): already a block.
            if (fn.name().hasPrefix(String.withCString("ParImpl$")))
                continue;
            _ppModule = m;
            Array* loops = self.lrcLoops(fn);
            for (u32 i = (u32)0; i < loops.count(); i = i + (u32)1)
                {
                LRCLoop* L = (LRCLoop*)loops.get(i);
                bool inner = false;
                for (u32 j = (u32)0; j < loops.count() && !inner; j = j + (u32)1)
                    {
                    LRCLoop* M = (LRCLoop*)loops.get(j);
                    if (M != L && M.header() != L.header() && self.hasBlock(M.body(), L.header()))
                        inner = true;
                    }
                if (inner)
                    continue;
                IRInsn* at = self.ppFirstDbg(L);
                if (at == (IRInsn*)0)
                    continue;
                String* path = (String*)IRDbg.files().get(at.dbgFile());
                if (path == (String*)0 || IRDbg.isLibraryPath(path))
                    continue;
                String* why = self.ppVerdict(fn, L);
                String* line = String.withFormat("propose: %s:%ld: ", path.cString(), (i32)at.dbgLine());
                if (why == (String*)0)
                    {
                    line.appendCString("wrap\n");
                    // Triangular: an inner loop whose bound moves with this
                    // loop's variable. The block is the outer loop for now;
                    // a grid over the bounding box (or tiles balanced by
                    // row length) needs the IR's outlining (step 3).
                    if (ppTriangular(fn, L, loops))
                        line.append(String.withFormat("propose: %s:%ld: shape triangular\n", path.cString(), (i32)at.dbgLine()));
                    }
                else
                    {
                    line.appendCString("no (");
                    line.append(why);
                    line.appendCString(")\n");
                    }
                Stdio.error(line);
                }
            }
        }
    }
