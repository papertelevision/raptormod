// FrameStep.cs -- pieces of the watcher's frame loop (tools\Watch-HostRender.ps1) moved out of script.
//
// 2026-10-13 PERFORMANCE AUDIT (docs\performance-audit-2026-10-13.md, [[azrael-perf-audit]]): about 3-5 ms of every
// frame was PowerShell itself -- function calls, [ref] marshalling, boxing. Each method here is a run of calls the
// script made one by one, in the same order with the same arguments, so the picture is identical. Compiled with the
// watcher's own types (Overlay, GpuRaster, VisorShade): the watcher's Add-Type list only.
using System;

namespace AztTool
{
    public static class FrameStep
    {
        /// <summary>THE CARD'S HAND-OVER, steady path (Step-TrueColour, phase 3): the overlay's latest reading of the screen
        /// is composed over this frame's picture on the card, then either read back (dyn: the processor still decorates this
        /// frame) or presented straight into the card's window with the visor's shading. Returns the key colour's share as
        /// TakeSurface gave it (per thousand; -1 = the screen cannot be read) -- nothing is composed when no reading came back.</summary>
        public static int ComposePresent(Overlay o, GpuRaster gq, int pw, int ph, int minShare, float sharpen, int gameW, int gameH, bool dyn, VisorShade vs)
        {
            int sk, share, sst;
            int[] scr = o.TakeSurface(minShare, out sk, out share, out sst);
            if (scr == null) return share;
            int[] cxi, cxf, cxiR, cxfR, riy, rwy; int bandTop, bandBot; bool visor;
            o.ComposeMap(pw, ph, out cxi, out cxf, out cxiR, out cxfR, out riy, out rwy, out bandTop, out bandBot, out visor);
            gq.SetComposeMap(cxi, cxf, cxiR, cxfR, riy, rwy);
            gq.PostCompose(sharpen, scr, sst, gameW, gameH, sk, bandTop, bandBot, visor);
            if (dyn) { gq.StartRead(); return share; }
            // the visor's shading as VisorShade.Draw lays it (only while it is on: the game's own copy hidden)
            if (vs != null && vs.Enabled) { int rows; byte[] cov = vs.CoverageFor(pw, o.ViewRowsOf(ph), out rows); gq.SetPresentShade(cov, pw, rows, vs.Color); }
            else gq.SetPresentShade(null, 0, 0, 0);
            if (gq.PresentGpu()) o.NoteGlFrame();
            return share;
        }
    }
}
