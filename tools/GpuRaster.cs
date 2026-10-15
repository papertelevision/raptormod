// GpuRaster.cs -- the true-colour room drawn by the GRAPHICS CARD instead of the processor.
//
// PHASE 0 (go/no-go, measured: 1.3 ms against 7 ms): the room and its characters, textured
// with the painted / upscaled originals, depth-tested, the holes (palette index 0) cut out.
// PHASE 1: Raster's true-colour LOOK term for term -- its mip choice, the room level, the
// helmet lamp (cone, halo, falloff, facing), placed lights and fog (CopyLighting takes them
// from the processor renderer every frame).
// PHASE 2: the rest of the processor's picture --
//   * SHADOWS: the helmet lamp's (one map, or a pair) and each placed light's, drawn as depth
//     pictures on the card and looked up with Raster's own soft test (ShadowSoftAt: the 2x2
//     compare, two diagonal taps), thinned with distance like Raster's;
//   * WATER: the pixels where a pool is the nearest thing are marked (stencil), the room is
//     drawn again mirrored through the water's height into them, only what lies BEYOND the
//     surface (against a copy of the depth picture, per pixel, as Raster's MaskBeyond), dimmed
//     and laid over the water's own colour;
//   * DUST: the motes (worked out on the processor by Motes.Gather) drawn as soft dots.
// Each is set before Draw for that frame (SetLampShadow, SetLightShadow, AddWater, SetMotes)
// and used up by it.
//
// The picture is drawn off screen and read back into an int[] (0x00RRGGBB, top row first),
// which is exactly what the overlay already takes from Raster.Color32, so nothing downstream
// changes.
//
// Plain OpenGL through opengl32.dll: nothing to install, no compiler beyond Add-Type. The
// context lives on a hidden window and belongs to the thread that created it -- every call
// must come from that thread (the watcher's own loop). OpenGL 4.5's glClipControl is required
// (every depth here is 1/z, as Raster's). NO GEOMETRY SHADERS: on this AMD driver one was
// handed the same values for all three corners of every triangle; per-triangle numbers are
// worked out in C# and sent as vertex data instead.
//
// The camera is Raster's exactly: the engine's world matrix (row-vector convention), vertical
// field of view, near plane, and screen = centre + (x, -y) * focal / z. Depth is near/z
// ("reverse Z" in a float buffer): the far distance is unlimited and precise. The picture is
// drawn upside down so that row 0 of every buffer is the TOP row, as in Raster's arrays.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace AztTool
{
    public class GpuRaster : IDisposable
    {
        // ---- Win32 / WGL -----------------------------------------------------------------------
        [StructLayout(LayoutKind.Sequential)]
        struct PIXELFORMATDESCRIPTOR
        {
            public ushort nSize, nVersion; public uint dwFlags;
            public byte iPixelType, cColorBits, cRedBits, cRedShift, cGreenBits, cGreenShift, cBlueBits, cBlueShift, cAlphaBits, cAlphaShift;
            public byte cAccumBits, cAccumRedBits, cAccumGreenBits, cAccumBlueBits, cAccumAlphaBits, cDepthBits, cStencilBits, cAuxBuffers, iLayerType, bReserved;
            public uint dwLayerMask, dwVisibleMask, dwDamageMask;
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(int ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("gdi32.dll")] static extern bool SwapBuffers(IntPtr dc);
        [StructLayout(LayoutKind.Sequential)] struct WRECT { public int l, t, r, b; }
        [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out WRECT r);
        [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
        [DllImport("gdi32.dll")] static extern int ChoosePixelFormat(IntPtr dc, ref PIXELFORMATDESCRIPTOR p);
        [DllImport("gdi32.dll")] static extern bool SetPixelFormat(IntPtr dc, int fmt, ref PIXELFORMATDESCRIPTOR p);
        [DllImport("opengl32.dll")] static extern IntPtr wglCreateContext(IntPtr dc);
        [DllImport("opengl32.dll")] static extern bool wglMakeCurrent(IntPtr dc, IntPtr ctx);
        [DllImport("opengl32.dll")] static extern bool wglDeleteContext(IntPtr ctx);
        [DllImport("opengl32.dll", CharSet = CharSet.Ansi)] static extern IntPtr wglGetProcAddress(string name);

        // ---- OpenGL 1.1 (exported by opengl32.dll itself) -------------------------------------
        [DllImport("opengl32.dll")] static extern IntPtr glGetString(uint name);
        [DllImport("opengl32.dll")] static extern uint glGetError();
        [DllImport("opengl32.dll")] static extern void glViewport(int x, int y, int w, int h);
        [DllImport("opengl32.dll")] static extern void glClearColor(float r, float g, float b, float a);
        [DllImport("opengl32.dll")] static extern void glClearDepth(double d);
        [DllImport("opengl32.dll")] static extern void glClearStencil(int s);
        [DllImport("opengl32.dll")] static extern void glClear(uint mask);
        [DllImport("opengl32.dll")] static extern void glEnable(uint cap);
        [DllImport("opengl32.dll")] static extern void glDisable(uint cap);
        [DllImport("opengl32.dll")] static extern void glDepthFunc(uint f);
        [DllImport("opengl32.dll")] static extern void glDepthMask(byte on);
        [DllImport("opengl32.dll")] static extern void glColorMask(byte r, byte g, byte b, byte a);
        [DllImport("opengl32.dll")] static extern void glStencilFunc(uint func, int reff, uint mask);
        [DllImport("opengl32.dll")] static extern void glStencilOp(uint sfail, uint dpfail, uint dppass);
        [DllImport("opengl32.dll")] static extern void glStencilMask(uint mask);
        [DllImport("opengl32.dll")] static extern void glBlendFunc(uint s, uint d);
        [DllImport("opengl32.dll")] static extern void glPolygonOffset(float factor, float units);
        [DllImport("opengl32.dll")] static extern void glCullFace(uint m);
        [DllImport("opengl32.dll")] static extern void glFrontFace(uint m);
        [DllImport("opengl32.dll")] static extern void glDrawBuffer(uint m);
        [DllImport("opengl32.dll")] static extern void glReadBuffer(uint m);
        [DllImport("opengl32.dll")] static extern void glGenTextures(int n, uint[] ids);
        [DllImport("opengl32.dll")] static extern void glDeleteTextures(int n, uint[] ids);
        [DllImport("opengl32.dll")] static extern void glBindTexture(uint target, uint id);
        [DllImport("opengl32.dll")] static extern void glTexParameteri(uint target, uint pname, int v);
        [DllImport("opengl32.dll")] static extern void glTexParameterf(uint target, uint pname, float v);
        [DllImport("opengl32.dll")] static extern void glTexImage2D(uint target, int level, int ifmt, int w, int h, int border, uint fmt, uint type, int[] px);
        [DllImport("opengl32.dll", EntryPoint = "glTexImage2D")] static extern void glTexImage2DB(uint target, int level, int ifmt, int w, int h, int border, uint fmt, uint type, byte[] px);
        [DllImport("opengl32.dll", EntryPoint = "glTexImage2D")] static extern void glTexImage2DN(uint target, int level, int ifmt, int w, int h, int border, uint fmt, uint type, IntPtr px);
        [DllImport("opengl32.dll")] static extern void glPixelStorei(uint pname, int v);
        [DllImport("opengl32.dll")] static extern void glTexSubImage2D(uint target, int level, int x, int y, int w, int h, uint fmt, uint type, int[] px);
        [DllImport("opengl32.dll", EntryPoint = "glTexSubImage2D")] static extern void glTexSubImage2DN(uint target, int level, int x, int y, int w, int h, uint fmt, uint type, IntPtr px);
        [DllImport("opengl32.dll")] static extern void glReadPixels(int x, int y, int w, int h, uint fmt, uint type, int[] px);
        [DllImport("opengl32.dll", EntryPoint = "glReadPixels")] static extern void glReadPixelsF(int x, int y, int w, int h, uint fmt, uint type, float[] px);
        [DllImport("opengl32.dll", EntryPoint = "glReadPixels")] static extern void glReadPixelsN(int x, int y, int w, int h, uint fmt, uint type, IntPtr offset);
        [DllImport("opengl32.dll")] static extern void glScissor(int x, int y, int w, int h);
        [DllImport("opengl32.dll")] static extern void glDrawArrays(uint mode, int first, int count);
        [DllImport("opengl32.dll")] static extern void glFinish();

        // ---- later OpenGL, fetched from the driver --------------------------------------------
        delegate void D_GenN(int n, uint[] ids);
        delegate void D_Bind(uint target, uint id);
        delegate void D_BufF(uint target, IntPtr size, float[] data, uint usage);
        delegate void D_UInt(uint a);
        delegate void D_AttrPtr(uint idx, int size, uint type, byte norm, int stride, IntPtr ptr);
        delegate uint D_CreateShader(uint type);
        delegate uint D_CreateProgram();
        delegate void D_ShaderSource(uint sh, int count, [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPStr)] string[] src, int[] len);
        delegate void D_GetIv(uint obj, uint pname, out int v);
        delegate void D_GetLog(uint obj, int max, out int len, StringBuilder log);
        delegate void D_Attach(uint prog, uint sh);
        delegate int D_GetUniform(uint prog, [MarshalAs(UnmanagedType.LPStr)] string name);
        delegate void D_Uni1i(int loc, int v);
        delegate void D_Uni1f(int loc, float v);
        delegate void D_Uni2f(int loc, float a, float b);
        delegate void D_Uni3f(int loc, float a, float b, float c);
        delegate void D_Uni4f(int loc, float a, float b, float c, float d);
        delegate void D_Uni2i(int loc, int a, int b);
        delegate void D_Uni3i(int loc, int a, int b, int c);
        delegate void D_UniV(int loc, int count, float[] v);
        delegate void D_UniIV(int loc, int count, int[] v);
        delegate void D_UniMat(int loc, int count, byte transpose, float[] v);
        delegate void D_FbTex(uint target, uint attach, uint textarget, uint tex, int level);
        delegate void D_RbStorage(uint target, uint ifmt, int w, int h);
        delegate void D_FbRb(uint target, uint attach, uint rbtarget, uint rb);
        delegate uint D_CheckFb(uint target);
        delegate void D_ClipControl(uint origin, uint depth);
        delegate void D_Blit(int sx0, int sy0, int sx1, int sy1, int dx0, int dy0, int dx1, int dy1, uint mask, uint filter);
        delegate void D_BlendColor(float r, float g, float b, float a);
        delegate void D_BufN(uint target, IntPtr size, IntPtr data, uint usage);
        delegate IntPtr D_MapRange(uint target, IntPtr offset, IntPtr length, uint access);
        delegate byte D_Unmap(uint target);
        delegate void D_TexImage3D(uint target, int level, int ifmt, int w, int h, int d, int border, uint fmt, uint type, float[] px);
        D_TexImage3D glTexImage3D;

        D_GenN glGenBuffers, glGenVertexArrays, glGenFramebuffers, glGenRenderbuffers, glDeleteBuffers, glDeleteVertexArrays, glDeleteFramebuffers, glDeleteRenderbuffers;
        D_Bind glBindBuffer, glBindFramebuffer, glBindRenderbuffer;
        D_UInt glBindVertexArray, glEnableVertexAttribArray, glCompileShader, glLinkProgram, glUseProgram, glActiveTexture, glDeleteShader, glDeleteProgram;
        D_BufF glBufferDataF;
        D_AttrPtr glVertexAttribPointer;
        D_CreateShader glCreateShader; D_CreateProgram glCreateProgram; D_ShaderSource glShaderSource;
        D_GetIv glGetShaderiv, glGetProgramiv; D_GetLog glGetShaderInfoLog, glGetProgramInfoLog;
        D_Attach glAttachShader; D_GetUniform glGetUniformLocationRaw;
        D_Uni1i glUniform1i; D_Uni1f glUniform1f; D_Uni2f glUniform2f; D_Uni3f glUniform3f; D_Uni4f glUniform4f; D_Uni2i glUniform2i; D_Uni3i glUniform3i;
        D_UniV glUniform1fv, glUniform2fv, glUniform3fv, glUniform4fv; D_UniIV glUniform1iv; D_UniMat glUniformMatrix4fv, glUniformMatrix3fv;
        D_FbTex glFramebufferTexture2D; D_RbStorage glRenderbufferStorage; D_FbRb glFramebufferRenderbuffer; D_CheckFb glCheckFramebufferStatus;
        D_ClipControl glClipControl; D_Blit glBlitFramebuffer; D_BlendColor glBlendColor;
        D_BufN glBufferDataN; D_MapRange glMapBufferRange; D_Unmap glUnmapBuffer; D_UInt glGenerateMipmap, glBlendEquation;

        T Get<T>(string name, bool required = true) where T : class
        {
            IntPtr p = wglGetProcAddress(name);
            long v = p.ToInt64();
            if (v == 0 || v == 1 || v == 2 || v == 3 || v == -1)
            {
                if (required) throw new InvalidOperationException("the graphics driver has no " + name);
                return null;
            }
            return Marshal.GetDelegateForFunctionPointer(p, typeof(T)) as T;
        }

        // ---- constants ---------------------------------------------------------------------------
        const uint GL_VENDOR = 0x1F00, GL_RENDERER = 0x1F01, GL_VERSION = 0x1F02;
        const uint GL_TEXTURE_2D = 0x0DE1, GL_TEXTURE0 = 0x84C0, GL_RGBA8 = 0x8058, GL_R8 = 0x8229, GL_RED = 0x1903, GL_RG8 = 0x822B, GL_RG = 0x8227, GL_BGRA = 0x80E1, GL_UNSIGNED_BYTE = 0x1401, GL_FLOAT = 0x1406;
        const uint GL_TEXTURE_MIN_FILTER = 0x2801, GL_TEXTURE_MAG_FILTER = 0x2800, GL_TEXTURE_WRAP_S = 0x2802, GL_TEXTURE_WRAP_T = 0x2803, GL_REPEAT = 0x2901, GL_CLAMP_TO_EDGE = 0x812F;
        const uint GL_NEAREST = 0x2600, GL_LINEAR = 0x2601, GL_LINEAR_MIPMAP_LINEAR = 0x2703, GL_TEXTURE_MAX_LEVEL = 0x813D, GL_TEXTURE_MAX_ANISOTROPY = 0x84FE;
        const uint GL_UNPACK_ALIGNMENT = 0x0CF5, GL_PACK_ALIGNMENT = 0x0D05;
        const uint GL_ARRAY_BUFFER = 0x8892, GL_STREAM_DRAW = 0x88E0;
        const uint GL_VERTEX_SHADER = 0x8B31, GL_FRAGMENT_SHADER = 0x8B30, GL_COMPILE_STATUS = 0x8B81, GL_LINK_STATUS = 0x8B82;
        const uint GL_FRAMEBUFFER = 0x8D40, GL_READ_FRAMEBUFFER = 0x8CA8, GL_DRAW_FRAMEBUFFER = 0x8CA9, GL_RENDERBUFFER = 0x8D41, GL_COLOR_ATTACHMENT0 = 0x8CE0;
        const uint GL_DEPTH_ATTACHMENT = 0x8D00, GL_DEPTH_STENCIL_ATTACHMENT = 0x821A, GL_DEPTH_COMPONENT32F = 0x8CAC, GL_DEPTH32F_STENCIL8 = 0x8CAD;
        const uint GL_DEPTH_COMPONENT = 0x1902, GL_DEPTH_STENCIL = 0x84F9, GL_FLOAT_32_UNSIGNED_INT_24_8_REV = 0x8DAD, GL_FRAMEBUFFER_COMPLETE = 0x8CD5, GL_NONE = 0;
        const uint GL_DEPTH_TEST = 0x0B71, GL_CULL_FACE = 0x0B44, GL_STENCIL_TEST = 0x0B90, GL_BLEND = 0x0BE2, GL_POLYGON_OFFSET_FILL = 0x8037, GL_PROGRAM_POINT_SIZE = 0x8642;
        const uint GL_BACK = 0x0405, GL_CCW = 0x0901, GL_CW = 0x0900;
        const uint GL_ALWAYS = 0x0207, GL_EQUAL = 0x0202, GL_GREATER = 0x0204, GL_GEQUAL = 0x0206, GL_KEEP = 0x1E00, GL_REPLACE = 0x1E01;
        const uint GL_SCISSOR_TEST = 0x0C11, GL_FUNC_ADD = 0x8006, GL_MAX = 0x8008;
        const uint GL_ONE = 1, GL_ONE_MINUS_SRC_ALPHA = 0x0303, GL_CONSTANT_ALPHA = 0x8003, GL_ONE_MINUS_CONSTANT_ALPHA = 0x8004, GL_SRC_ALPHA = 0x0302, GL_DST_COLOR = 0x0306;
        const uint GL_TRIANGLES = 0x0004, GL_POINTS = 0x0000;
        const uint GL_COLOR_BUFFER_BIT = 0x4000, GL_DEPTH_BUFFER_BIT = 0x0100, GL_STENCIL_BUFFER_BIT = 0x0400;
        const uint GL_LOWER_LEFT = 0x8CA1, GL_ZERO_TO_ONE = 0x935F;
        const uint GL_R32I = 0x8235, GL_RED_INTEGER = 0x8D94, GL_INT = 0x1404, GL_UNPACK_ROW_LENGTH = 0x0CF2;
        const uint GL_PIXEL_UNPACK_BUFFER = 0x88EC, GL_MAP_WRITE_BIT = 0x0002, GL_MAP_INVALIDATE_BUFFER_BIT = 0x0008;
        uint _screenPbo, _readPbo; bool _readPending;
        const uint GL_PIXEL_PACK_BUFFER = 0x88EB, GL_STREAM_READ = 0x88E1, GL_MAP_READ_BIT = 0x0001;

        // ---- state ------------------------------------------------------------------------------
        IntPtr _hwnd, _dc, _rc;
        public readonly int W, H;
        public string Vendor, Renderer, Version;
        public bool ReverseZ;
        uint _pMain, _pDepth, _pClear, _pMote;
        uint _fbo, _colorTex, _depthTex, _surfFbo, _surfTex;
        uint _pWater, _reflFbo, _reflTex;       // MODERN WATER (2026-10-08): the surface's own pass, and the mirrored room as a picture it reads
        uint _pNorm, _normFbo, _pPart, _pVao, _pVbo;
        float[] _parts = new float[0]; int _partN, _partAlpha;
        /// <summary>The particles for the next Draw: Particles.Gather's output (alpha ones first).</summary>
        public void SetParticles(float[] data, int n)
        {
            if (data == null || n <= 0) { _partN = 0; return; }
            if (_parts.Length < n * 10) _parts = new float[n * 10];
            Array.Copy(data, _parts, n * 10); _partN = n;
            _partAlpha = 0; while (_partAlpha < n && _parts[_partAlpha * 10 + 8] < 0.5f) _partAlpha++;
        }
        public int LastParticles;
        /// <summary>RELIEF: how strongly the bump maps bend the light (0 = flat, as the processor draws).</summary>
        public float Relief = 1f;
        /// <summary>How steep the bump maps are made from a texture's brightness (applied when a texture is uploaded).</summary>
        public float ReliefBuild = 24f;          // measured: 4 tilted the typical bump 2-6 degrees (invisible); 24 gives 5-25
        /// <summary>SHARP RELIEF (Josh, 2026-10-07: the relief "makes the textures look lower resolution"). The first maps
        /// are half the colour's size, made from its half-size copy, and read a level blurrier still -- their bumps are
        /// 2-4x coarser than the picture they light, so they smear it. The sharp maps are made at the colour's FULL size
        /// from its full-size brightness, with a 3x3 (Sobel) slope instead of a two-texel difference, weighted to the
        /// finest detail (one texel minus a 4-texel blur) over the middle scale, and read at the colour's own level.
        /// Two channels (the third is worked out in the shader). ReliefSharpBuild: make them for textures uploaded while
        /// it is set (the watcher sets it per room); ReliefSharp: draw with them where they exist (F7 compares).</summary>
        public bool ReliefSharp = true, ReliefSharpBuild = false;
        public float ReliefSharpK = 36f;    // 36: MEASURED on CORICORI to give the old maps' steepness (mean slope 0.150 vs 0.160, p90 0.52 vs 0.54) -- the same depth, finer
        /// <summary>THE RELIEF'S SCALE (Josh, 2026-10-07: the sharp relief "feels too large ... can it be scaled smaller").
        /// A sharp map keeps its two layers apart, mixed live: ReliefFine (1-2 texel bumps) and ReliefMid (2-8 texels).
        /// ReliefTile lays the map smaller than the colour (2 = half size) -- but MEASURED on MINEHEAD it pulls in the
        /// relief of whatever else shares the texture file (its floor grew a woven grid from a neighbouring piece), so it
        /// stays 1 unless asked. The old half-size maps are untouched by all three.</summary>
        public float ReliefFine = 1f, ReliefMid = 0.35f, ReliefTile = 1f;
        /// <summary>PER-PIXEL MIPMAPS (Josh, 2026-10-07: "texture detail softens in the distance to prevent shimmering").
        /// The first card renderer copied the processor's choice: ONE level per triangle, from its size and the angle at
        /// its middle -- so the far end of a long floor or wall, seen at a glancing angle, kept far too much detail and
        /// sparkled. PixelMip lets the card choose per pixel from how fast the texture runs across the screen there,
        /// both ways, with anisotropic filtering (Anisotropy) so floors soften only along the direction they recede.
        /// PixelMipBias: below 0 sharper (more shimmer), above 0 softer; NormMipBias: the relief a little softer still,
        /// as fine bumps under a moving lamp sparkle before colour does.</summary>
        public bool PixelMip = true;
        public float PixelMipBias = 0f, NormMipBias = 1.0f;
        /// <summary>The most the relief may brighten (or 1/x darken) a pixel against its face's own lighting. Was unlimited
        /// (~3.5x on floors at a glancing angle: blown-out blobs); 99 = as before. Applies with the sharp maps only.</summary>
        public float ReliefGain = 1.6f;
        /// <summary>Relief shadows in the texture's own colour, as a multiply layer would make them (0 = plain darkening,
        /// which reads grey on these desaturated stones). How strongly, at a full shadow. With the sharp maps only.</summary>
        /// <summary>The relief's opacity, as a layer's: 1 = full, 0.8 = 80% relief-lit / 20% flat. Texture relief and
        /// micro relief together, with the sharp maps only (Josh, 2026-10-07: "lets try at 80% opacity").</summary>
        public float ReliefOpacity = 0.5f;     // (Josh: 80%, then 50%)
        public float ReliefTint = 3f;      // MEASURED on CORICORI (mist off): 3 lifts the shadows' saturation ~10% (0.42 -> 0.46), grey-black grain -> brown
        /// <summary>MICRO RELIEF (Josh, 2026-10-07: "I really want a high resolution feel for these normal maps"). Relief
        /// made from a texture can never be finer than its texels, and on stretched textures those are big. This is
        /// generated instead: stone-like bumps from 3D gradient noise at each pixel's place in the WORLD, so it has no
        /// texel size, no seams and borrows nothing from neighbouring art. Layers from DetailScale world units down,
        /// each half the size; each fades out as it nears two pixels across (no shimmer). Detail = slope strength
        /// (0 = off; the watcher sets it per room), DetailRough = each finer layer's share, DetailAO = hollows darkened.
        /// One stone-like grain for every surface for now (wood and metal get it too); on a moving door or creature the
        /// grain stays in the world rather than on the object.</summary>
        float _detailNow;
        public float Detail = 0f, DetailScale = 0.8f, DetailRough = 0.85f, DetailAO = 0.10f; public int DetailOctaves = 4;     // Josh: 1.2, then 15% finer (1.02), then picked the finer 0.8 (strength 0.4, set by the watcher)
        // (MEASURED on CORICORI: starting at 4 units with each layer 0.6 of the last, the coarse layer won and read as
        // blotchy mottling -- "large" again. 1.2 units down to 0.15, nearly equal slopes per layer, strength 0.3 reads
        // as fine rock grain. +1.6 ms of card time a frame.)     // 1.0: the relief one level softer than the colour (0.5 still sparkled on MINEHEAD's lit floor)
        public int SharpMaps; public long SharpBytes;
        uint _pSharp, _pComp, _postFbo, _postTex, _compFbo, _compTex, _screenTex, _mapTex; int _screenW, _screenH; object _mapKey;   // phase 3
        uint _wVao, _wVbo, _mVao, _mVbo, _eVao;
        float[] _view = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        float _focal = 1f;
        public float NearZ = 0.5f;
        public float MipBias = -0.35f;
        public float Anisotropy = 8f;               // anisotropic filtering, with PixelMip (2026-10-07; was 1 = off, as the processor's renderer has none). Set before textures go up.

        /// <summary>MATERIALS (2026-10-12, Josh: "Shine where it belongs"): each texture's highlight (Raster.Tex.Shine, Gloss,
        /// Metal, ShineVary -- the watcher sets them from rooms\_materials.json). ShineOn / ShineGain: all of it, and how strong
        /// (the watcher's -NoShine / -Shine / F6). ShineLampX/Y: where the lamp's highlight comes from (view space: the lamp
        /// pair's middle). GlowGain: a companion glow map's texels at that many times their own colour, at least.
        /// ReliefHeightK: a companion height map's relief steepness (it replaces the art's brightness; -1 = ReliefSharpK).</summary>
        public bool ShineOn = true; public float ShineGain = 1f, ShineLampX = 0f, ShineLampY = 8f, GlowGain = 1f, ReliefHeightK = -1f;
        /// <summary>THE RELIEF (normal mapping) and the micro relief, off and on in play (Josh, 2026-10-12: "a toggle for the normal
        /// mapping as well so I can compare all three effects" -- with the shine (ShineOn) and the wet (WetOn)). The maps stay
        /// on the card; only their use is switched.</summary>
        public bool ReliefOn = true;
        /// <summary>THE VISOR MATERIALIZES THE ROOM (Josh, 2026-10-13: "When ANALYZING ENVIRONMENT reaches 100%, surfaces sweep in
        /// from a scan wireframe to full texture in a fast wave, as if the HUD has just rendered the room ... the teal color we've
        /// used"; round 2: "the wave happens too quickly ... a much more smooth/sleek animation, so slow it down but also have a
        /// lingering trail after the main illuminations. Perhaps some dot based small pixels also surrounding the trailing pulse
        /// effects. Also we need to see the full wireframe being outlined in the outward manner even if they extend beyond the
        /// players visibility" and "make the water join the wave too"). StartMaterialize: TWO fronts run out from the eye, each
        /// easing up to speed from rest -- the WIRE front (MatWireSpeed units/s) draws the polygons' teal outlines outward over
        /// dark glass; MatDelay later the TEXTURE front (MatSpeed) turns them to full texture with a glow band, and behind it the
        /// outlines linger and fade over MatTrail seconds with specks of light (MatDots) about the fronts and in the trail. It
        /// runs until the texture front has passed the room's farthest corner from where the sweep began (its reach, measured
        /// on the first frame) and the trail has died -- nothing is cut off. The water's surface fades in with the texture
        /// front. MatBand = the fronts' width (units). Colours: ScanWire.Teal / TealFlare. MaterializeOn: -NoMaterialize.</summary>
        public bool MaterializeOn = true;
        public float MatSpeed = 1100f, MatWireSpeed = 950f, MatDelay = 0.6f, MatBand = 80f, MatTrail = 0.35f, MatDots = 1f, MatReach = 1400f;
        public int MatColor = 0x5FD8C0, MatFlare = 0xCFFFF4;
        Stopwatch _matClock; double _matOffset; float _matReach = -1f;
        float _mfTex, _mfWire, _matT; bool _matNow; readonly Stopwatch _matIdle = Stopwatch.StartNew();
        /// <summary>A LOAD'S DARK GLASS (Josh, 2026-10-13: "not displaying any of the game until all loading is complete"): while
        /// set, the room is drawn as the sweep's start -- dark glass, no outlines yet -- so a loading panel fading out shows
        /// nothing of the game; StartMaterialize lets it go.</summary>
        public volatile bool MatHold;
        /// <summary>The sweep for the visor's "Scanning..." label (ScanWire.cs ScanTag): how far the texture front has crossed
        /// the room (0..1), and the label's strength (1 while the outlines are up, fading with the trail; 0 = no sweep).</summary>
        public float MatProgress, MatTagK;
        /// <summary>A sweep is running.</summary>
        public bool Materializing { get { return _matClock != null; } }
        public void StartMaterialize() { StartMaterializeAt(0); }
        /// <summary>...as if it had started `seconds` ago (the offline test's way to a moment of it).</summary>
        public void StartMaterializeAt(double seconds) { MatHold = false; if (!MaterializeOn) return; _matClock = Stopwatch.StartNew(); _matOffset = seconds; _matReach = -1f; _matSweep++; }
        static float EaseFront(double u) { return u <= 0 ? 0f : (float)(u - (1.0 - Math.Exp(-3.0 * u)) / 3.0); }      // (from rest up to full speed, smoothly)
        /// <summary>This frame's fronts (and, on the sweep's first frame, how far the room reaches from the eye).</summary>
        void UpdateMaterialize(float[] vx)
        {
            _matNow = false; MatProgress = 0f; MatTagK = 0f;
            if (_matClock == null)
            {
                if (MatHold && MaterializeOn) { _matNow = true; _mfTex = 0f; _mfWire = 0f; _matT = (float)(_matIdle.Elapsed.TotalSeconds % 1000.0); }
                return;
            }
            if (_matReach < 0f)
            {
                float ex = _camWorld[12], ey = _camWorld[13], ez = _camWorld[14], m2 = 0f;
                if (vx != null) for (int i = 0; i + 2 < vx.Length; i += 3) { float dx = vx[i] - ex, dy = vx[i + 1] - ey, dz = vx[i + 2] - ez, d2 = dx * dx + dy * dy + dz * dz; if (d2 > m2) m2 = d2; }
                _matReach = m2 > 1f ? Math.Min(4000f, (float)Math.Sqrt(m2)) : MatReach;
            }
            double t = _matClock.Elapsed.TotalSeconds + _matOffset; _matT = (float)t;
            _mfWire = EaseFront(t) * MatWireSpeed; _mfTex = EaseFront(t - MatDelay) * MatSpeed;
            if (_mfTex > _matReach + MatSpeed * MatTrail + 3f * MatBand) { _matClock = null; return; }
            _matNow = true;
            MatProgress = Math.Min(1f, _mfTex / Math.Max(1f, _matReach));
            float tagEnd = _mfTex - _matReach, tagLen = MatSpeed * MatTrail + MatBand;
            MatTagK = tagEnd <= 0f ? 1f : Math.Max(0f, 1f - tagEnd / Math.Max(1f, tagLen));
        }        public void StopMaterialize() { _matClock = null; _matNow = false; MatHold = false; }
        /// <summary>PARALLAX DEPTH (Josh, 2026-10-12, phase 4a: "Mortar lines, planks and stone blocks appear sunken as you move
        /// past, using the height we already compute. Flat walls and floors gain real depth"): each texture gets a height map
        /// (HeightOf: a companion "_height" map where there is one, else the art's own brightness with its painted light taken
        /// away -- dark grooves deep), and the room's shader steps the view ray into it (parallax occlusion mapping), so the
        /// texture is read where the ray meets the sunken surface. ParallaxDepth: how far below the face its deepest texel
        /// lies (world units; x a room's "parallax"); ParallaxFar: gone by this distance (it fades from half way); ParallaxSteps:
        /// the most steps along a ray (glancing views take them all). Switched with the relief (ReliefOn, the watcher's F7);
        /// ONLY WHERE A TEXTURE'S MATERIAL TAKES IT (Raster.Tex.Parallax: stone, floor and rock walls and floors -- Josh, in game
        /// 2026-10-12: "cool in some cases and others not ... the bridge in the spa room ... looks weirdly bumpy and unnatural ...
        /// limit this to walls and floors, but not the wooden plank style floors"), and not on art whose grain runs one way
        /// (planks named like stone: ParallaxGrainMax) unless named by hand;
        /// none on shiny surfaces (their material's relief 0), what moves, faces mixed against repeats, reflections.</summary>
        public bool ParallaxOn = true; public float ParallaxDepth = 1f, ParallaxFar = 260f, ParallaxGrainMax = 0.58f; public int ParallaxSteps = 24;
        /// <summary>WALLS AND FLOORS (Josh, 2026-10-12): a texture takes the parallax only where it covers at least ParallaxShellArea
        /// square units of the room in triangles of ParallaxShellMean on average (SetParallaxShell, per room) -- the room's own
        /// walls and floors; props (a figure, a sign, a mirror, a pillar) stay flat unless named by hand.</summary>
        public float ParallaxShellArea = 5000f, ParallaxShellMean = 100f;
        bool SurfacePom(Raster.Tex t) { return t != null && t.Parallax > 0f && !t.Moves && (t.ParallaxSet || _pomShell.Contains(t)); }
        readonly HashSet<Raster.Tex> _pomShell = new HashSet<Raster.Tex>();
        /// <summary>This room's wall-and-floor textures (see ParallaxShellArea). Returns how many.</summary>
        public int SetParallaxShell(float[] vx, int[] idx, int[] triTex, Raster.Tex[] texes)
        {
            _pomShell.Clear();
            if (vx == null || idx == null || triTex == null || texes == null) return 0;
            var sum = new double[texes.Length]; var cnt = new int[texes.Length]; int nT = Math.Min(idx.Length / 3, triTex.Length), nV = vx.Length / 3;
            for (int t = 0; t < nT; t++)
            {
                int ti = triTex[t]; if (ti < 0 || ti >= texes.Length || texes[ti] == null) continue;
                int a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2]; if (a >= nV || b >= nV || c >= nV) continue;
                double e1x = vx[b * 3] - vx[a * 3], e1y = vx[b * 3 + 1] - vx[a * 3 + 1], e1z = vx[b * 3 + 2] - vx[a * 3 + 2], e2x = vx[c * 3] - vx[a * 3], e2y = vx[c * 3 + 1] - vx[a * 3 + 1], e2z = vx[c * 3 + 2] - vx[a * 3 + 2];
                double cx = e1y * e2z - e1z * e2y, cy = e1z * e2x - e1x * e2z, cz = e1x * e2y - e1y * e2x;
                sum[ti] += 0.5 * Math.Sqrt(cx * cx + cy * cy + cz * cz); cnt[ti]++;
            }
            var tot = new Dictionary<Raster.Tex, double[]>();
            for (int i = 0; i < texes.Length; i++) { if (texes[i] == null || cnt[i] == 0) continue; double[] s; if (!tot.TryGetValue(texes[i], out s)) { s = new double[2]; tot[texes[i]] = s; } s[0] += sum[i]; s[1] += cnt[i]; }
            foreach (var kv in tot) if (kv.Value[0] >= ParallaxShellArea && kv.Value[0] / kv.Value[1] >= ParallaxShellMean) _pomShell.Add(kv.Key);
            return _pomShell.Count;
        }
        /// <summary>The card has a 19th texture unit for the height maps (UNIT_HEIGHT); without one there is no parallax.</summary>
        public bool DepthUnitOk; public int HeightMaps; public long HeightBytes; public double HeightMs;
        /// <summary>THE WATER'S SHEEN (Josh, 2026-10-12: "a glossy sheen ... applied to water surfaces to reflect the lights"): the
        /// modern water's broad soft highlight of the lamp and the lights (a room's water block "sheen", "sheenGloss"), under
        /// the materials' switch. Water drawn without the modern water takes its material's ("water" in _materials.json).</summary>
        public float WaterSheen = 0.35f, WaterSheenGloss = 30f;
        /// <summary>The card has a 17th texture unit for the companion maps (UNIT_MAT); without one they are left out.</summary>
        public bool MatUnitOk;
        /// <summary>WET SURFACES (Josh, 2026-10-12, phase 2: damp caves and the spa rooms): a room's "wet" block (the watcher
        /// sets these and SetGround). WetStrength 0..1; WetHeight: how far up the walls the damp reaches above the floor
        /// beneath them (units, a ragged line); WetDark: the colour's level at full wet; WetFloor: floors' dampness; WetShine /
        /// WetGloss: the water film's highlight; WetPuddles: the share of the (level) floor under puddles, WetPuddleSize their
        /// scale (units); WetWalls: the walls' share (Josh, caves: half); WetCeiling: ceilings' dampness. WetOn: all of it (the
        /// watcher's F5 / -NoWet). Each texture's share is its material's (Raster.Tex.Wet). (Trickles down the walls were
        /// tried and taken out: Josh, 2026-10-12, "the dripping water on the walls isn't working".)</summary>
        public bool WetOn = true;
        public float WetStrength = 1f, WetHeight = 45f, WetDark = 0.62f, WetFloor = 0.45f, WetShine = 0.16f, WetGloss = 40f, WetPuddles = 0.3f, WetPuddleSize = 70f;
        public float WetWalls = 1f, WetCeiling = 0.15f;
        /// <summary>The art's dark parts stay dry (Josh, 2026-10-12, CORICORI): the wet fades in from WetDarkFrom to WetDarkTo of
        /// the texture's brightness round each point (0..255, a coarse copy of the art about 64 texels across).</summary>
        public float WetDarkFrom = 10f, WetDarkTo = 45f;
        /// <summary>The card has an 18th texture unit for the floor's height (UNIT_GROUND); without one no room is wet.</summary>
        public bool WetUnitOk;
        /// <summary>Testing: 1 = draw how wet (red), puddles (green), height over the floor (blue) instead of the room.</summary>
        public int WetDebug;
        public string GroundNote = "";
        uint _groundTex; float _gx0, _gz0, _gInv;
        /// <summary>No room's floor heights: nothing is wet.</summary>
        public void ClearGround() { if (_groundTex != 0) { glDeleteTextures(1, new[] { _groundTex }); _groundTex = 0; } GroundNote = ""; }
        /// <summary>THE FLOOR UNDER EVERY POINT of a room, for its damp: per cell (x, z) the height of the lowest surface facing up
        /// with room above it, of those within 150 units of the cell's highest -- under a walkway the damp rises from the water.
        /// Which way a floor's winding faces is read from the room itself (its lowest level faces up); metal (pipes) is no
        /// floor, nor a top with under 30 units of room above it. Cells beside the floor take their neighbours' (walls stand on
        /// its edge); the rest far below (dry). False if the room has no floor.</summary>
        public bool SetGround(float[] v, int[] t, int[] triTex, Raster.Tex[] texes, float cell)
        {
            ClearGround();
            if (v == null || t == null || triTex == null || cell < 1f || v.Length < 9) return false;
            float x0 = float.MaxValue, x1 = float.MinValue, z0 = float.MaxValue, z1 = float.MinValue;
            for (int i = 0; i + 2 < v.Length; i += 3) { x0 = Math.Min(x0, v[i]); x1 = Math.Max(x1, v[i]); z0 = Math.Min(z0, v[i + 2]); z1 = Math.Max(z1, v[i + 2]); }
            while ((x1 - x0) / cell > 1000 || (z1 - z0) / cell > 1000) cell *= 2f;
            int nx = (int)Math.Ceiling((x1 - x0) / cell) + 3, nz = (int)Math.Ceiling((z1 - z0) / cell) + 3;
            float gx0 = x0 - cell, gz0 = z0 - cell;
            int nT = Math.Min(t.Length / 3, triTex.Length);
            // the faces that lie flat-ish (|ny| > 0.6), each with its signed facing and middle height
            var flat = new List<int>(); var fy = new List<float>(); var fs = new List<float>(); var fa = new List<float>();
            for (int k = 0; k < nT; k++)
            {
                int ti = triTex[k]; if (ti < 0 || texes == null || ti >= texes.Length || texes[ti] == null) continue;
                if (texes[ti].Metal >= 0.4f) continue;          // (a pipe's top or a wheel is not a floor: the wall under it is no wetter)
                int a = t[k * 3] * 3, b = t[k * 3 + 1] * 3, c = t[k * 3 + 2] * 3;
                float ux = v[b] - v[a], uy = v[b + 1] - v[a + 1], uz = v[b + 2] - v[a + 2], wx = v[c] - v[a], wy = v[c + 1] - v[a + 1], wz = v[c + 2] - v[a + 2];
                float nx3 = uy * wz - uz * wy, ny3 = uz * wx - ux * wz, nz3 = ux * wy - uy * wx; float nl = (float)Math.Sqrt(nx3 * nx3 + ny3 * ny3 + nz3 * nz3);
                if (nl < 1e-6f || Math.Abs(ny3 / nl) < 0.6f) continue;
                flat.Add(k); fs.Add(ny3 / nl); fy.Add((v[a + 1] + v[b + 1] + v[c + 1]) / 3f); fa.Add(nl * 0.5f);
            }
            if (flat.Count == 0) { GroundNote = "no floor"; return false; }
            // which sign is up: the lowest fifth of the flat faces (by area) are floors
            var order = new int[flat.Count]; for (int i = 0; i < order.Length; i++) order[i] = i;
            var keys = fy.ToArray(); Array.Sort(keys, order);
            double total = 0; foreach (var ar in fa) total += ar;
            double acc = 0, vote = 0; foreach (int i in order) { if (acc > total * 0.2) break; acc += fa[i]; vote += fa[i] * Math.Sign(fs[i]); }
            float upSign = vote >= 0 ? 1f : -1f;
            var g = new float[nx * nz]; for (int i = 0; i < g.Length; i++) g[i] = float.NaN;
            int ups = 0, hidden = 0; var sCell = new List<int>(); var sY = new List<float>();
            for (int f = 0; f < flat.Count; f++)
            {
                if (fs[f] * upSign <= 0f) continue;          // facing down: a ceiling
                int k = flat[f], a = t[k * 3] * 3, b = t[k * 3 + 1] * 3, c = t[k * 3 + 2] * 3;
                // a floor has room above it: a box's top hidden in a wall (SPAROOM's doors, their tops at the lintel) has none
                {
                    float mx = (v[a] + v[b] + v[c]) / 3f, my = (v[a + 1] + v[b + 1] + v[c + 1]) / 3f, mz = (v[a + 2] + v[b + 2] + v[c + 2]) / 3f;
                    if (Raster.RayDistance(v, t, triTex, mx, my + 0.5f, mz, 0f, 1f, 0f, 40f) < 30f) { hidden++; continue; }
                }
                ups++;
                float ax = v[a], az = v[a + 2], ay = v[a + 1], bx = v[b], bz = v[b + 2], by = v[b + 1], cx = v[c], cz = v[c + 2], cy = v[c + 1];
                float den = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz); if (Math.Abs(den) < 1e-6f) continue;
                int i0 = Math.Max(0, (int)Math.Floor((Math.Min(ax, Math.Min(bx, cx)) - gx0) / cell)), i1 = Math.Min(nx - 1, (int)Math.Floor((Math.Max(ax, Math.Max(bx, cx)) - gx0) / cell));
                int j0 = Math.Max(0, (int)Math.Floor((Math.Min(az, Math.Min(bz, cz)) - gz0) / cell)), j1 = Math.Min(nz - 1, (int)Math.Floor((Math.Max(az, Math.Max(bz, cz)) - gz0) / cell));
                bool any = false;
                for (int j = j0; j <= j1; j++) for (int i = i0; i <= i1; i++)
                {
                    float px = gx0 + (i + 0.5f) * cell, pz = gz0 + (j + 0.5f) * cell;
                    float l1 = ((bz - cz) * (px - cx) + (cx - bx) * (pz - cz)) / den, l2 = ((cz - az) * (px - cx) + (ax - cx) * (pz - cz)) / den, l3 = 1f - l1 - l2;
                    if (l1 < -0.02f || l2 < -0.02f || l3 < -0.02f) continue;
                    sCell.Add(j * nx + i); sY.Add(l1 * ay + l2 * by + l3 * cy); any = true;
                }
                if (!any)
                {   // (smaller than a cell: its middle counts)
                    int i = (int)Math.Floor(((ax + bx + cx) / 3f - gx0) / cell), j = (int)Math.Floor(((az + bz + cz) / 3f - gz0) / cell);
                    if (i >= 0 && i < nx && j >= 0 && j < nz) { sCell.Add(j * nx + i); sY.Add((ay + by + cy) / 3f); }
                }
            }
            // each cell: the LOWEST floor there, of those within 150 units of its highest -- the damp rises from the water under
            // a walkway, and a box's top higher up (a door's lintel) is not where the floor is; far below is not this room
            var gmax = new float[nx * nz]; for (int i = 0; i < gmax.Length; i++) gmax[i] = float.NaN;
            for (int s = 0; s < sCell.Count; s++) { int o = sCell[s]; if (float.IsNaN(gmax[o]) || sY[s] > gmax[o]) gmax[o] = sY[s]; }
            for (int s = 0; s < sCell.Count; s++) { int o = sCell[s]; float y = sY[s]; if (y < gmax[o] - 150f) continue; if (float.IsNaN(g[o]) || y < g[o]) g[o] = y; }
            // the floor's edge carried a few cells outward (the walls stand there), the rest far below
            for (int pass = 0; pass < 4; pass++)
            {
                var n2 = (float[])g.Clone();
                for (int j = 0; j < nz; j++) for (int i = 0; i < nx; i++)
                {
                    if (!float.IsNaN(g[j * nx + i])) continue;
                    float best = float.NaN;
                    for (int dj = -1; dj <= 1; dj++) for (int di = -1; di <= 1; di++)
                    {
                        int ii = i + di, jj = j + dj; if (ii < 0 || jj < 0 || ii >= nx || jj >= nz) continue;
                        float q = g[jj * nx + ii]; if (!float.IsNaN(q) && (float.IsNaN(best) || q > best)) best = q;
                    }
                    n2[j * nx + i] = best;
                }
                g = n2;
            }
            int known = 0; for (int i = 0; i < g.Length; i++) { if (float.IsNaN(g[i])) g[i] = -100000f; else known++; }
            var ids = new uint[1]; glGenTextures(1, ids); _groundTex = ids[0];
            glBindTexture(GL_TEXTURE_2D, _groundTex);
            var h = GCHandle.Alloc(g, GCHandleType.Pinned);
            try { glTexImage2DN(GL_TEXTURE_2D, 0, 0x822E /* R32F */, nx, nz, 0, 0x1903 /* RED */, 0x1406 /* FLOAT */, h.AddrOfPinnedObject()); }
            finally { h.Free(); }
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_CLAMP_TO_EDGE);
            glBindTexture(GL_TEXTURE_2D, 0);
            Check("the room's floor heights");
            _gx0 = gx0; _gz0 = gz0; _gInv = 1f / cell;
            GroundNote = string.Format("{0}x{1} cells of {2:0} units, {3} of {4} flat faces are floors (winding {5}; {6} facing up with no room above them left out), {7} cells under a floor or beside one", nx, nz, cell, ups, flat.Count, upSign > 0 ? "+y" : "-y", hidden, known);
            return true;
        }
        // per texture: the picture (with its own mip chain) and the hole mask
        // (Used: the Upload call that last needed it, for evicting the least recently used; SharpB: its sharp relief map's share of Bytes;
        // Mat: its companion maps (smoothness, height, glow), MatSrc the Tex.MatPx they came from)
        class GTex { public uint Rgb, Mask, Norm, NormHi, Mat, Height; public long Bytes, Used, SharpB, MatB, HeightB; public int MatHas; public byte[] ArtSrc, IdxSrc; public int[] MatSrc, HeightSrc; public float Grain, HeightShade; public bool HeightDone; }
        readonly Dictionary<Raster.Tex, GTex> _tex = new Dictionary<Raster.Tex, GTex>();
        public long TextureBytes;
        long _useStamp;
        /// <summary>Textures dropped from the card to stay under MaxTextureBytes (least recently used first, never the room's own).</summary>
        public long Evicted;
        // textures held on the card at most. Was a fixed 1.5 GB; Josh's own 4096 room textures (2026-10-08) need ~1.4 GB
        // in one room with their relief maps, and a room over the budget re-uploads every frame. So: 1/8 of the
        // machine's memory (the card's memory is the computer's own on these machines), between 1.5 and 4 GB.
        public long MaxTextureBytes = DefaultTextureBudget();
        /// <summary>The card's memory as its driver reports it (bytes; 0 = it would not say).</summary>
        public long CardMemoryBytes;
        [DllImport("opengl32.dll")] static extern void glGetIntegerv(uint pname, int[] data);
        [StructLayout(LayoutKind.Sequential)] class MEMSTAT { public uint dwLength = 64, dwMemoryLoad; public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual; }
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx([In, Out] MEMSTAT m);
        public static long DefaultTextureBudget()
        {
            long lo = 1536L << 20, hi = 4096L << 20;
            try { var m = new MEMSTAT(); if (GlobalMemoryStatusEx(m)) return Math.Max(lo, Math.Min(hi, (long)(m.ullTotalPhys / 8))); } catch { }
            return lo;
        }
        public int TexturesUploaded;

        public double LastDrawMs, LastReadMs, LastUploadMs; public int LastBatches, LastTris, LastShadowViews, LastWaterGroups, LastMotes;

        public static GpuRaster Create(int w, int h, out string error)
        {
            error = null;
            var g = new GpuRaster(w, h);
            try { g.Init(); return g; }
            catch (Exception e) { error = e.Message; try { g.Dispose(); } catch { } return null; }
        }

        GpuRaster(int w, int h) { if (w < 16 || h < 16) throw new ArgumentException("bad size"); W = w; H = h; }

        void Init()
        {
            // a hidden window only to hang the context on; the picture itself is drawn off screen
            _hwnd = CreateWindowExW(0, "STATIC", "AztGpu", 0x80000000u /* WS_POPUP, never shown */, 0, 0, 16, 16, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (_hwnd == IntPtr.Zero) throw new InvalidOperationException("could not make the hidden window for the graphics context");
            _dc = GetDC(_hwnd);
            var pfd = new PIXELFORMATDESCRIPTOR();
            pfd.nSize = (ushort)Marshal.SizeOf(typeof(PIXELFORMATDESCRIPTOR)); pfd.nVersion = 1;
            pfd.dwFlags = 0x4 | 0x20 | 0x1;        // DRAW_TO_WINDOW | SUPPORT_OPENGL | DOUBLEBUFFER
            pfd.iPixelType = 0; pfd.cColorBits = 32; pfd.cDepthBits = 24; pfd.iLayerType = 0;
            int fmt = ChoosePixelFormat(_dc, ref pfd);
            if (fmt == 0 || !SetPixelFormat(_dc, fmt, ref pfd)) throw new InvalidOperationException("no OpenGL pixel format on this machine");
            _pfd = pfd; _pfmt = fmt;          // (the card's own window takes the same format: AttachPresent)
            _rc = wglCreateContext(_dc);
            if (_rc == IntPtr.Zero || !wglMakeCurrent(_dc, _rc)) throw new InvalidOperationException("could not create an OpenGL context");
            Vendor = Str(GL_VENDOR); Renderer = Str(GL_RENDERER); Version = Str(GL_VERSION);
            // THE CARD'S OWN MEMORY (Josh, 2026-10-08: "my card has 16gigs ... dedicated"): asked of the driver -- AMD's
            // free texture memory (ATI_meminfo) or NVIDIA's dedicated memory (NVX_gpu_memory_info) -- and the texture budget
            // set from it; failing both, the RAM rule (DefaultTextureBudget)
            try
            {
                var mi = new int[4];
                while (glGetError() != 0) { }
                glGetIntegerv(0x87FC, mi);                                 // TEXTURE_FREE_MEMORY_ATI: free KB first
                long kb = glGetError() == 0 ? mi[0] : 0;
                if (kb <= 0) { mi[0] = 0; glGetIntegerv(0x9047, mi); kb = glGetError() == 0 ? mi[0] : 0; }      // DEDICATED_VIDMEM_NVX, KB
                if (kb > 0)
                {
                    CardMemoryBytes = kb * 1024L;
                    // most of it for textures: the rest for the pictures, shadow maps and everything else on the card
                    MaxTextureBytes = Math.Max(1536L << 20, Math.Min(10L << 30, (long)(CardMemoryBytes * 0.65)));     // (10 GB at most: on a chip that shares system memory the driver counts that too -- Josh's 8060S says 46.7 GB of a 16 GB carve-out)
                }
            }
            catch { }
            if (Renderer != null && Renderer.IndexOf("GDI Generic", StringComparison.OrdinalIgnoreCase) >= 0)
                throw new InvalidOperationException("only Windows' software OpenGL is available (no graphics driver)");

            glGenBuffers = Get<D_GenN>("glGenBuffers"); glGenVertexArrays = Get<D_GenN>("glGenVertexArrays");
            glGenFramebuffers = Get<D_GenN>("glGenFramebuffers"); glGenRenderbuffers = Get<D_GenN>("glGenRenderbuffers");
            glDeleteBuffers = Get<D_GenN>("glDeleteBuffers"); glDeleteVertexArrays = Get<D_GenN>("glDeleteVertexArrays");
            glDeleteFramebuffers = Get<D_GenN>("glDeleteFramebuffers"); glDeleteRenderbuffers = Get<D_GenN>("glDeleteRenderbuffers");
            glBindBuffer = Get<D_Bind>("glBindBuffer"); glBindFramebuffer = Get<D_Bind>("glBindFramebuffer"); glBindRenderbuffer = Get<D_Bind>("glBindRenderbuffer");
            glBindVertexArray = Get<D_UInt>("glBindVertexArray"); glEnableVertexAttribArray = Get<D_UInt>("glEnableVertexAttribArray");
            glCompileShader = Get<D_UInt>("glCompileShader"); glLinkProgram = Get<D_UInt>("glLinkProgram"); glUseProgram = Get<D_UInt>("glUseProgram");
            glActiveTexture = Get<D_UInt>("glActiveTexture"); glDeleteShader = Get<D_UInt>("glDeleteShader"); glDeleteProgram = Get<D_UInt>("glDeleteProgram");
            glBufferDataF = Get<D_BufF>("glBufferData");
            glVertexAttribPointer = Get<D_AttrPtr>("glVertexAttribPointer");
            glCreateShader = Get<D_CreateShader>("glCreateShader"); glCreateProgram = Get<D_CreateProgram>("glCreateProgram"); glShaderSource = Get<D_ShaderSource>("glShaderSource");
            glGetShaderiv = Get<D_GetIv>("glGetShaderiv"); glGetProgramiv = Get<D_GetIv>("glGetProgramiv");
            glGetShaderInfoLog = Get<D_GetLog>("glGetShaderInfoLog"); glGetProgramInfoLog = Get<D_GetLog>("glGetProgramInfoLog");
            glAttachShader = Get<D_Attach>("glAttachShader"); glGetUniformLocationRaw = Get<D_GetUniform>("glGetUniformLocation");
            glUniform1i = Get<D_Uni1i>("glUniform1i"); glUniform1f = Get<D_Uni1f>("glUniform1f"); glUniform2f = Get<D_Uni2f>("glUniform2f");
            glUniform3f = Get<D_Uni3f>("glUniform3f"); glUniform4f = Get<D_Uni4f>("glUniform4f"); glUniform2i = Get<D_Uni2i>("glUniform2i"); glUniform3i = Get<D_Uni3i>("glUniform3i");
            glUniform1fv = Get<D_UniV>("glUniform1fv"); glUniform2fv = Get<D_UniV>("glUniform2fv"); glUniform3fv = Get<D_UniV>("glUniform3fv"); glUniform4fv = Get<D_UniV>("glUniform4fv"); glUniform1iv = Get<D_UniIV>("glUniform1iv");
            glUniformMatrix4fv = Get<D_UniMat>("glUniformMatrix4fv"); glUniformMatrix3fv = Get<D_UniMat>("glUniformMatrix3fv");
            glFramebufferTexture2D = Get<D_FbTex>("glFramebufferTexture2D"); glRenderbufferStorage = Get<D_RbStorage>("glRenderbufferStorage");
            glFramebufferRenderbuffer = Get<D_FbRb>("glFramebufferRenderbuffer"); glCheckFramebufferStatus = Get<D_CheckFb>("glCheckFramebufferStatus");
            glBlitFramebuffer = Get<D_Blit>("glBlitFramebuffer"); glBlendColor = Get<D_BlendColor>("glBlendColor");
            glBufferDataN = Get<D_BufN>("glBufferData"); glMapBufferRange = Get<D_MapRange>("glMapBufferRange"); glUnmapBuffer = Get<D_Unmap>("glUnmapBuffer"); glGenerateMipmap = Get<D_UInt>("glGenerateMipmap");
            glBlendEquation = Get<D_UInt>("glBlendEquation", false);
            glClipControl = Get<D_ClipControl>("glClipControl", false);
            glTexImage3D = Get<D_TexImage3D>("glTexImage3D", false);
            if (glClipControl == null) throw new InvalidOperationException("the graphics driver has no glClipControl (OpenGL 4.5)");

            _pMain = Link(VS_MAIN, FS_MAIN, "the picture");
            _pDepth = Link(VS_DEPTH, FS_DEPTH, "depth views");
            _pClear = Link(VS_CLEAR, FS_CLEAR, "depth clearing");
            _pMote = Link(VS_MOTE, FS_MOTE, "dust");
            _pSharp = Link(VS_CLEAR, FS_SHARP, "sharpening");
            _pComp = Link(VS_CLEAR, FS_COMP, "laying the game's drawings over the picture");
            _pNorm = Link(VS_CLEAR, FS_NORM, "relief maps");
            _pPart = Link(VS_PART, FS_PART, "particles");
            _pWater = Link(VS_WATER, FS_WATER, "water surfaces");
            { var pid = new uint[1]; glGenVertexArrays(1, pid); _pVao = pid[0]; glBindVertexArray(_pVao); glGenBuffers(1, pid); _pVbo = pid[0]; glBindBuffer(GL_ARRAY_BUFFER, _pVbo);
              glEnableVertexAttribArray(0); glVertexAttribPointer(0, 4, GL_FLOAT, 0, 40, IntPtr.Zero);
              glEnableVertexAttribArray(1); glVertexAttribPointer(1, 4, GL_FLOAT, 0, 40, new IntPtr(16));
              glEnableVertexAttribArray(2); glVertexAttribPointer(2, 2, GL_FLOAT, 0, 40, new IntPtr(32)); glBindVertexArray(0); }
            { var nid = new uint[1]; glGenFramebuffers(1, nid); _normFbo = nid[0]; }
            LocateUniforms();
            { var mu = new int[1]; glGetIntegerv(0x8872, mu); MatUnitOk = mu[0] > UNIT_MAT; MapUnitOk = mu[0] > UNIT_MAP; WetUnitOk = mu[0] > UNIT_GROUND; DepthUnitOk = mu[0] > UNIT_HEIGHT; }      // (MAX_TEXTURE_IMAGE_UNITS: the companion maps', the floor heights' and the height maps' units)

            var ids = new uint[1];
            // the picture: colour, and depth + stencil as a texture (copied for the water's test)
            glGenFramebuffers(1, ids); _fbo = ids[0];
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
            _colorTex = ColourTex();
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _colorTex, 0);
            _depthTex = DepthStencilTex();
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, _depthTex, 0);
            Complete("the picture");
            // the copy of the depth picture the water reads ("is this beyond the surface?")
            glGenFramebuffers(1, ids); _surfFbo = ids[0];
            glBindFramebuffer(GL_FRAMEBUFFER, _surfFbo);
            _surfTex = DepthStencilTex();
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, _surfTex, 0);
            glDrawBuffer(GL_NONE); glReadBuffer(GL_NONE);
            Complete("the depth copy");
            // the room mirrored in the water, as its own picture (sharing the picture's depth + stencil), for the water's
            // surface to read at rippled places; filtered, so the ripples bend it smoothly
            glGenFramebuffers(1, ids); _reflFbo = ids[0]; glBindFramebuffer(GL_FRAMEBUFFER, _reflFbo);
            _reflTex = ColourTex();
            glBindTexture(GL_TEXTURE_2D, _reflTex);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_CLAMP_TO_EDGE);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _reflTex, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, _depthTex, 0);
            Complete("the water's reflection");
            // after the picture: sharpened, then the game's drawings laid over it (PostCompose)
            glGenFramebuffers(1, ids); _postFbo = ids[0]; glBindFramebuffer(GL_FRAMEBUFFER, _postFbo);
            _postTex = ColourTex(); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _postTex, 0); Complete("the sharpened picture");
            glGenFramebuffers(1, ids); _compFbo = ids[0]; glBindFramebuffer(GL_FRAMEBUFFER, _compFbo);
            _compTex = ColourTex(); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _compTex, 0); Complete("the finished picture");

            // vertex sets: the room, and the room mirrored for water (10 floats a vertex)
            _main = NewSet(); _mirror = NewSet();
            // water surfaces (position + a dummy uv) and dust (x, y, depth, radius; lit, dark)
            glGenVertexArrays(1, ids); _wVao = ids[0]; glBindVertexArray(_wVao);
            glGenBuffers(1, ids); _wVbo = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _wVbo);
            glEnableVertexAttribArray(0); glVertexAttribPointer(0, 3, GL_FLOAT, 0, 20, IntPtr.Zero);
            glEnableVertexAttribArray(1); glVertexAttribPointer(1, 2, GL_FLOAT, 0, 20, new IntPtr(12));
            glGenVertexArrays(1, ids); _mVao = ids[0]; glBindVertexArray(_mVao);
            glGenBuffers(1, ids); _mVbo = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _mVbo);
            glEnableVertexAttribArray(0); glVertexAttribPointer(0, 4, GL_FLOAT, 0, 24, IntPtr.Zero);
            glEnableVertexAttribArray(1); glVertexAttribPointer(1, 2, GL_FLOAT, 0, 24, new IntPtr(16));
            glGenVertexArrays(1, ids); _eVao = ids[0];
            glBindVertexArray(0);

            // depth as near/z: near plane 1, infinitely far 0, "greater is nearer"
            glClipControl(GL_LOWER_LEFT, GL_ZERO_TO_ONE); ReverseZ = true;
            glPixelStorei(GL_UNPACK_ALIGNMENT, 1); glPixelStorei(GL_PACK_ALIGNMENT, 4);
            Check("setting up");
        }
        uint ColourTex()
        {
            var ids = new uint[1]; glGenTextures(1, ids);
            glBindTexture(GL_TEXTURE_2D, ids[0]);
            glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_RGBA8, W, H, 0, GL_BGRA, GL_UNSIGNED_BYTE, IntPtr.Zero);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            return ids[0];
        }
        uint DepthStencilTex()
        {
            var ids = new uint[1]; glGenTextures(1, ids);
            glBindTexture(GL_TEXTURE_2D, ids[0]);
            glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_DEPTH32F_STENCIL8, W, H, 0, GL_DEPTH_STENCIL, GL_FLOAT_32_UNSIGNED_INT_24_8_REV, IntPtr.Zero);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            return ids[0];
        }
        void Complete(string what)
        {
            uint st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
            if (st != GL_FRAMEBUFFER_COMPLETE) throw new InvalidOperationException(what + ": off-screen buffer not usable (status 0x" + st.ToString("X") + ")");
        }

        static string Str(uint name) { IntPtr p = glGetString(name); return p == IntPtr.Zero ? null : Marshal.PtrToStringAnsi(p); }
        void Check(string what) { uint e = glGetError(); if (e != 0) throw new InvalidOperationException("OpenGL error 0x" + e.ToString("X") + " " + what); }

        // ---- shaders ---------------------------------------------------------------------------
        // The room. The once-per-triangle numbers -- how squarely the face looks back at the lamp,
        // its normal, its texel density -- arrive as vertex data, the same on all three corners.
        const string VS_MAIN = @"#version 400 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 2) in vec4 aTri;      // facing toward the lamp, then the face normal (view space)
layout(location = 3) in float aLod;     // the face's texel density as a mip level, before depth
layout(location = 4) in vec4 aRange;    // TEXTURE REPAIR: the part of the texture a re-laid face ping-pongs in (lo u, lo v, size u, size v)
layout(location = 5) in float aFix;     // and its flags: 1 / 2 ping-pong along u / v, 4 / 8 mixed against repeats along u / v
uniform mat4 uView; uniform vec2 uF; uniform float uNear; uniform float uOffY;
out vec2 vUv; out vec3 vView; out vec4 vTri; out float vLod; out vec3 vWorld; flat out vec4 vRange; flat out int vFix;
out vec3 vBary;      // (the materialize sweep's outlines: which corner, as every triangle has its own three on the card)
invariant gl_Position;
void main() {
    vec4 p = uView * vec4(aPos, 1.0);
    vUv = aUv; vView = p.xyz; vTri = aTri; vLod = aLod; vWorld = aPos; vRange = aRange; vFix = int(aFix + 0.5);
    int corner = gl_VertexID % 3; vBary = vec3(corner == 0 ? 1.0 : 0.0, corner == 1 ? 1.0 : 0.0, corner == 2 ? 1.0 : 0.0);
    // screen = centre + (x, -y) * focal / z, as Raster.Prepare; depth = near / z
    gl_Position = vec4(p.x * uF.x, -p.y * uF.y + uOffY * p.z, uNear, p.z);
}";
        const string FS_MAIN = @"#version 400 core
in vec2 vUv; in vec3 vView; in vec4 vTri; in float vLod; in vec3 vWorld; flat in vec4 vRange; flat in int vFix; in vec3 vBary;
uniform mat4 uView;
// THE VISOR MATERIALIZES THE ROOM (GpuRaster.StartMaterialize): uMatz = the texture front's distance from the eye (units), the
// fronts' width, the wire front's distance, on; uMatX = its clock (s), the trail's fade (s), the texture front's speed, the
// specks; uMatC / uMatF the scan's teal and its flare (0..255)
uniform vec4 uMatz, uMatX; uniform vec3 uMatC, uMatF;
// TEXTURE REPAIR (GpuRaster.SetRelay): uMixOn -- surfaces that repeat their texture get it twice, shifted by amounts that change
// slowly across them (one change every 1 / uMixScale tiles or so), blended: the repeating grid breaks up
uniform int uMixOn; uniform float uMixScale; uniform int uRelayDebug;     // (testing: folded faces red, evened blue, mixed green, objects re-laid whole magenta)
// PARALLAX DEPTH (GpuRaster.Parallax*): this texture's height map (1 = the face, 0 = uPom.x units below it), uPomK its share
// (0: none, or what moves), uPom = depth, gone by (units away), most steps
uniform int uPomOn; uniform sampler2D uHeight; uniform float uPomK; uniform vec3 uPom;
vec2 gMixA = vec2(0.0), gMixB = vec2(0.0); float gMixT = 0.0;
// a texture read with the mix (k: how much smaller the map is laid than the colour, uNormTile)
vec4 fetchMix(sampler2D s, vec2 p, vec2 dx, vec2 dy, float l, float k, bool grad) {
    vec4 a = grad ? textureGrad(s, p + gMixA * k, dx, dy) : textureLod(s, p + gMixA * k, l);
    if (gMixT <= 0.0) return a;
    vec4 b = grad ? textureGrad(s, p + gMixB * k, dx, dy) : textureLod(s, p + gMixB * k, l);
    return mix(a, b, gMixT);
}
uniform sampler2D uTex; uniform sampler2D uMask;
uniform float uFlip; uniform float uNear; uniform vec2 uCentre;
// the helmet lamp
uniform int uLampOn; uniform float uLampRoom, uLampPower, uLampRange, uSpill, uHalo, uFpx;
uniform vec4 uCones;        // cos(inner), cos(outer), cos(halo inner), cos(halo outer)
uniform vec2 uLampC;        // the beam's centre on the screen, pixels from the top left
// its shadows: one map or a pair, the lamp's own orientation shifted by (ox, oy)
uniform int uLampMaps; uniform sampler2D uLampMap[2]; uniform vec2 uLampOff[2];
uniform vec3 uLampMapF;     // focal px, half width, half height
uniform ivec2 uLampMapSize;
uniform vec4 uShadow;       // 1 + bias, soft radius in texels, how dark, 1 + light bias
uniform vec2 uSFade;        // shadows thin out: far, 1 / max(1, far - near)
// THE MUZZLE FLASH (Josh, 2026-10-07: 'a muzzle flash of light that illuminates the surroundings, casting shadows'):
// a brief warm light from the gun, all round (no cone), by depth like the lamp, shadowed by the lamp pair's maps
uniform float uFlash, uFlashRange; uniform vec3 uFlashC; uniform float uLightDeep;
// placed lights (view space): xyz + 1/range^2 (or 1), colour x strength, and their shadow views
uniform int uLightCount; uniform vec4 uLightP[8]; uniform vec3 uLightC[8];
uniform int uLightMapOn[8]; uniform sampler2D uLightMap[8]; uniform mat3 uLightAx[8]; uniform vec2 uLightMapF[8];
// SPOTLIGHTS (2026-10-08): a light with a cone shines only within it (cos inner, cos outer; outer < -1.5 = all round),
// along its direction (view space)
uniform vec3 uLightDir[8]; uniform vec2 uLightCone[8];
// a light's colour shifting with distance (its 'colorFar', blended from tint distance .x to .y; multiplier 1 = none)
uniform vec3 uLightTintM[8]; uniform vec2 uLightTintD[8];
// WALL WASHES (2026-10-14, Josh, Room Review CHAMBNEW: an uplight under each spotlight painted on the walls -- twelve, past
// the eight placed lights): steady spotlights with no shadow view, up to 16 on top of the placed lights. View space:
// xyz + 1/range^2, colour x strength, direction, cos inner / cos outer
uniform int uWashN; uniform vec4 uWashP[16]; uniform vec3 uWashC[16]; uniform vec3 uWashDir[16]; uniform vec2 uWashCone[16];
// GLASS IN A TEXTURE'S HOLES (2026-10-14, Josh, BAPTIST/1 -- Raster.Tex.Glass): above 0, the texels cut out as holes are drawn
// as a pane at this share of their own colour times uGlassTint (the light behind it); the shadow views still let light through
uniform float uGlass; uniform vec3 uGlassTint;
// LIGHT GATES (2026-10-14, BAPTIST/1: a sun outside the windows of a room with no ceiling came in over the walls too): a placed
// light with a gate reaches only what it sees through that world box (its window's opening). .w of lo = on; uLightW: the
// lights' own places in the world
uniform vec4 uGateLo[8]; uniform vec3 uGateHi[8]; uniform vec3 uLightW[8];
// SCORCH MARKS (2026-10-14, Josh: shot impacts -- 'scorch marks that fade where your shots hit stone'): where shots landed
// (world xyz + radius; the surface's normal + age in seconds), a ragged sooty patch on that surface that fades over
// uScLife, glowing ember-hot at its middle for its first moments
uniform int uScN; uniform vec4 uScP[16]; uniform vec4 uScQ[16]; uniform float uScLife;
// THE ECHO SCAN'S SHELL (GpuRaster.EchoT): its radius from the eye, its band's width, strength (0 = none)
uniform vec3 uEcho;
bool segThrough(vec3 a, vec3 b, vec3 lo, vec3 hi) {
    vec3 d = b - a, inv = 1.0 / mix(d, vec3(1e-9), lessThan(abs(d), vec3(1e-9)));
    vec3 t0 = (lo - a) * inv, t1 = (hi - a) * inv, tn = min(t0, t1), tf = max(t0, t1);
    float n = max(max(max(tn.x, tn.y), tn.z), 0.0), f = min(min(min(tf.x, tf.y), tf.z), 1.0);
    return n <= f;
}
// ALL-ROUND shadow views (uLightMapOn 2): six 90-degree faces in one map, 3 across x 2 down, each face's axes here (view space)
uniform mat3 uCubeAx[6];
// SOFT CONTACT SHADOWS (2026-10-08): a placed light has a size (world units, 0 = the old hard edge), so its shadows are
// sharp where the caster touches (feet, a crate's base) and widen into a penumbra the farther they fall from it
uniform float uLightSoft; uniform float uSoftMax; uniform float uLampSoft;     // (uLampSoft: the flashlight's size, the same for its pair of maps)
// fog
uniform int uFogOn; uniform vec3 uFog; uniform vec3 uFogCol;     // near, 1/(far-near), max; colour 0..255
// a reflection in water: only beyond the surface, dimmed; no shadows, lights or fog (as Raster)
uniform int uRefl; uniform float uDim; uniform sampler2D uSurf;
// relief: the texture's bump map, bending the surface's direction pixel by pixel
uniform sampler2D uNorm; uniform float uRelief, uNormLod;     // uNormLod: 0 for a sharp (full-size) map, -1 for a half-size one
// this texture's share of the relief and micro relief (its material's 'relief': Josh, 2026-10-12, 'remove ... the relief mapping
// on shiny surfaces, because that makes them all look more grainy and textured where they should be shiny' -- metals,
// polished stone, glass, water 0)
uniform float uReliefK;
// a sharp map holds two layers (fine in xy, broad in zw) mixed here, and can be laid smaller than the colour (uNormTile)
uniform int uNormBands; uniform float uNormFine, uNormMid, uNormTile;
// PER-PIXEL MIPMAPS: the copy of the texture chosen from how fast it runs across the screen at THIS pixel, both ways
// (anisotropic), not one level per triangle; uMipK = 2^bias for the colour, uNormMipK for the relief (a little softer)
uniform int uPixelMip; uniform float uMipK, uNormMipK;
uniform float uReliefGain, uReliefTint, uReliefOp;
// MICRO RELIEF: stone-like bumps from 3D noise in the WORLD, finer than any texel (see GpuRaster.Detail)
uniform float uDetail, uDetailScale, uDetailAO, uDetailRough; uniform int uDetailOct;
// GLOWING WATER (Josh, 2026-10-08, SPAROOM: 'light sources beneath this water surface ... water-like light projections on
// the walls above'): light coming up out of each pool (box x0,z0,x1,z1 at height y) onto what is above it -- a soft fill
// plus moving caustic lines, fading with height (uCaus.w) and beyond the pool's edge; brighter near the lamps under the
// water (x, z, radius, strength). uCaus: strength, size, speed, height; uCausFill: the even part.
uniform int uWN; uniform vec4 uWBox[4]; uniform float uWY[4]; uniform vec4 uCaus; uniform float uCausFill, uTime;
uniform vec3 uGlowCol; uniform float uGlowBase; uniform int uWSpotN; uniform vec4 uWSpot[4];
// places the water's light must not reach (Josh, SPAROOM/2 round 5: not in the hallways): floor-plan boxes x0, z0, x1, z1
uniform int uWCutN; uniform vec4 uWCut[4];
// BOUNCED LIGHT (2026-10-09, GiBake): a grid of probes, each the light arriving from every direction as an L1 spherical
// harmonic per colour. One 3D texture, four slabs along z: red, green, blue (c00, c1x, c1y, c1z), then validity (r).
// uGiBox: the grid's corner + 1 / spacing; uGiK: its strength (x the torches' flicker); uGiAmb: the room's own level
// scaled while it is on (the bounce now does part of what the flat room level stood in for)
uniform float uLitR;     // 1 / (how far round an all-round light it clears the fog)^2 (alpha out: see the end)
uniform float uMirY;     // a reflection: the water's height it is mirrored through
uniform int uGiOn; uniform sampler3D uGi; uniform vec4 uGiBox; uniform ivec3 uGiN; uniform float uGiK, uGiAmb;
// LIGHT FROM THE ARTWORK (BuildArtLight): the original art's painted light and shade, per texel in the hole mask's second
// channel (1 = the art's well-lit level), shading the room's level and the bounce -- never the placed lights or the lamp.
// uRoomTint: the room's level in a colour (the art's own bright colour, 1 = white)
uniform int uArtOn; uniform vec3 uRoomTint;
// MATERIALS (2026-10-12, Josh: 'Shine where it belongs. Your helmet lamp would glint off brass and gold, give wet stone a
// sheen, and leave wood and cloth dull'): highlights of the lamp and the placed lights, per texture (Raster.Tex.Shine ...):
// uShine how strong (0 = matte), uGloss how tight (a Blinn exponent), uMetal how much the highlight takes the surface's own
// colour rather than the light's, uShineVary how much the art's brightness sets it texel by texel. uLampPos: the lamp (view
// space; the pair's middle). COMPANION MAPS in uMat (uMatHas: 1 smoothness, 2 height, 4 glow): smoothness replaces the art's
// guess (0.5 = the material as it is), glow draws those texels at their own colour whatever the light (x uGlowK).
uniform int uShineOn; uniform float uShine, uGloss, uMetal, uShineVary; uniform vec3 uLampPos;
uniform sampler2D uMat; uniform int uMatHas; uniform float uGlowK;
// WET SURFACES (Josh, 2026-10-12, phase 2: 'in the rooms with dripping like damp caves, and of course the spa room ... the
// lower walls and floors get a darker wet look with a glossy sheen ... and puddles reflect your lamp'): how wet each pixel is --
// walls damp up to a ragged line uWetA.y above the floor beneath them (uGround: the lowest floor per x, z), floors damp all
// over (a cave's not at all: only its puddles) with puddles on LEVEL floor, ceilings a little -- times this texture's share
// (uWetK: its material's 'wet'). (The trickles down the walls are gone: Josh, 'the dripping water on the walls isn't working'.)
uniform int uWetOn; uniform float uWetK;
uniform vec4 uWetA;      // strength, damp height (units), the colour's level at full wet, floors' dampness
uniform vec4 uWetB;      // the film's shine, its gloss, puddles (share of the floor), puddle size (units)
uniform vec4 uWetC;      // walls' share (Josh, caves: half), ceilings' dampness, the art's brightness the wet starts at / is full at (0..255)
uniform sampler2D uGround; uniform vec4 uGroundBox;      // x0, z0, 1 / cell size: the floor's height per cell (unknown = far below)
uniform int uWetDebug;   // (testing: 1 = the picture is how wet (red), puddles (green), height over the floor (blue, 0..2 x the damp height))
float groundAt(vec2 xz) { return texture(uGround, (xz - uGroundBox.xy) * uGroundBox.z / vec2(textureSize(uGround, 0))).r; }
float artAt(vec2 st) {
    ivec2 sz = textureSize(uMask, 0);
    vec2 p = st * vec2(sz) - 0.5, f = fract(p); ivec2 i = ivec2(floor(p));
    ivec2 a = ((i % sz) + sz) % sz, b = (((i + 1) % sz) + sz) % sz;      // (wrapped, as the texture repeats)
    float v00 = texelFetch(uMask, a, 0).g, v10 = texelFetch(uMask, ivec2(b.x, a.y), 0).g;
    float v01 = texelFetch(uMask, ivec2(a.x, b.y), 0).g, v11 = texelFetch(uMask, b, 0).g;
    return mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
}
out vec4 oColor;
" + NOISE_GLSL + @"
float soft(float t) { t = clamp(t, 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
// the bounced light reaching a surface at P (room) facing n (room): the 8 probes round it, nudged off the surface, the
// ones inside walls left out, each weighted by where P falls between them and by being on the side n faces
vec3 giAt(vec3 P, vec3 n) {
    vec3 q = (P + n * (0.3 / uGiBox.w) - uGiBox.xyz) * uGiBox.w;
    ivec3 b = ivec3(floor(q)); vec3 f = q - vec3(b);
    vec3 s = vec3(0.0); float ws = 0.0;
    for (int i = 0; i < 8; i++) {
        ivec3 o = ivec3(i & 1, (i >> 1) & 1, i >> 2), c = b + o;
        if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, uGiN))) continue;
        if (texelFetch(uGi, ivec3(c.x, c.y, c.z + 3 * uGiN.z), 0).r < 0.5) continue;
        vec3 tw = mix(1.0 - f, f, vec3(o));
        vec3 dp = vec3(c) / uGiBox.w + uGiBox.xyz - P;
        float bw = (dot(dp, n) * inversesqrt(dot(dp, dp) + 1e-4) + 1.0) * 0.5;
        float w = tw.x * tw.y * tw.z * (bw * bw + 0.05);
        vec4 r = texelFetch(uGi, c, 0), g = texelFetch(uGi, ivec3(c.x, c.y, c.z + uGiN.z), 0), bl = texelFetch(uGi, ivec3(c.x, c.y, c.z + 2 * uGiN.z), 0);
        vec3 e = vec3(r.x, g.x, bl.x) * 0.282095 + 0.325735 * vec3(dot(r.yzw, n), dot(g.yzw, n), dot(bl.yzw, n));
        s += w * max(e, vec3(0.0)); ws += w;
    }
    return ws > 1e-5 ? s / ws : vec3(0.0);
}
" + WATER_GLSL + FS_MAIN_TAIL;
        // (shared by the room's shader and the water's)
        const string NOISE_GLSL = @"
// an integer hash (pcg3d): steady at any distance from the origin, unlike a sin() hash
uvec3 pcg3d(uvec3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}
vec3 grad3(vec3 c) { uvec3 h = pcg3d(uvec3(ivec3(c) + ivec3(1 << 20))); return vec3(h >> 8u) * (2.0 / 16777215.0) - 1.0; }
// gradient noise and its exact slope: (value, d/dx, d/dy, d/dz) -- quintic blend, so the slope is smooth too
vec4 noised(vec3 x) {
    vec3 i = floor(x), f = x - i;
    vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    vec3 ga = grad3(i), gb = grad3(i + vec3(1, 0, 0)), gc = grad3(i + vec3(0, 1, 0)), gd = grad3(i + vec3(1, 1, 0));
    vec3 ge = grad3(i + vec3(0, 0, 1)), gf = grad3(i + vec3(1, 0, 1)), gg = grad3(i + vec3(0, 1, 1)), gh = grad3(i + vec3(1, 1, 1));
    float va = dot(ga, f), vb = dot(gb, f - vec3(1, 0, 0)), vc = dot(gc, f - vec3(0, 1, 0)), vd = dot(gd, f - vec3(1, 1, 0));
    float ve = dot(ge, f - vec3(0, 0, 1)), vf = dot(gf, f - vec3(1, 0, 1)), vg = dot(gg, f - vec3(0, 1, 1)), vh = dot(gh, f - vec3(1, 1, 1));
    float k1 = vb - va, k2 = vc - va, k3 = ve - va, k4 = va - vb - vc + vd, k5 = va - vc - ve + vg, k6 = va - vb - ve + vf, k7 = -va + vb + vc - vd + ve - vf - vg + vh;
    float v = va + u.x * k1 + u.y * k2 + u.z * k3 + u.x * u.y * k4 + u.y * u.z * k5 + u.z * u.x * k6 + u.x * u.y * u.z * k7;
    vec3 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.z * (ge - ga) + u.x * u.y * (ga - gb - gc + gd) + u.y * u.z * (ga - gc - ge + gg)
           + u.z * u.x * (ga - gb - ge + gf) + u.x * u.y * u.z * (-ga + gb + gc - gd + ge - gf - gg + gh)
           + du * vec3(k1 + u.y * k4 + u.z * k6 + u.y * u.z * k7, k2 + u.z * k5 + u.x * k4 + u.z * u.x * k7, k3 + u.x * k6 + u.y * k5 + u.x * u.y * k7);
    return vec4(v, d);
}
";
        const string FS_MAIN_TAIL = @"
// Raster.ShadowTap: four texels compared, blended by where the point falls between them
float tap(sampler2D m, vec2 s, float lim) {
    ivec2 i = ivec2(s); vec2 f = s - vec2(i);
    float a = texelFetch(m, i, 0).r > lim ? 1.0 : 0.0, b = texelFetch(m, i + ivec2(1, 0), 0).r > lim ? 1.0 : 0.0;
    float c = texelFetch(m, i + ivec2(0, 1), 0).r > lim ? 1.0 : 0.0, d = texelFetch(m, i + ivec2(1, 1), 0).r > lim ? 1.0 : 0.0;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
// Raster.ShadowSoftAt: -1 outside the map; settled by one look when the four agree; else two diagonal taps
float softAt(sampler2D m, ivec2 sz, vec2 s, float lim, float r) {
    if (s.x - r < 0.0 || s.y - r < 0.0 || s.x + r >= float(sz.x - 1) || s.y + r >= float(sz.y - 1)) return -1.0;
    ivec2 i = ivec2(s);
    bool a = texelFetch(m, i, 0).r > lim, b = texelFetch(m, i + ivec2(1, 0), 0).r > lim;
    bool c = texelFetch(m, i + ivec2(0, 1), 0).r > lim, d = texelFetch(m, i + ivec2(1, 1), 0).r > lim;
    if (a == b && b == c && c == d) { if (!a) return 0.0; if (r <= 0.0) return 1.0; }
    if (r <= 0.0) return tap(m, s, lim);
    return 0.5 * (tap(m, s - vec2(r), lim) + tap(m, s + vec2(r), lim));
}
// softAt for one face of an all-round map: s within the face, o the face's corner in the map
float tapO(sampler2D m, ivec2 o, vec2 s, float lim) {
    ivec2 i = o + ivec2(s); vec2 f = s - floor(s);
    float a = texelFetch(m, i, 0).r > lim ? 1.0 : 0.0, b = texelFetch(m, i + ivec2(1, 0), 0).r > lim ? 1.0 : 0.0;
    float c = texelFetch(m, i + ivec2(0, 1), 0).r > lim ? 1.0 : 0.0, d = texelFetch(m, i + ivec2(1, 1), 0).r > lim ? 1.0 : 0.0;
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float softTile(sampler2D m, ivec2 o, float fsz, vec2 s, float lim, float r) {
    s = clamp(s, vec2(r), vec2(fsz - 2.0 - r));             // (the face's own 90 degrees end 3 texels in from its edge)
    if (r <= 0.0) return tapO(m, o, s, lim);
    return 0.5 * (tapO(m, o, s - vec2(r), lim) + tapO(m, o, s + vec2(r), lim));
}
// PCSS on one face of an all-round map. s: the point in the face (texels), lz: its distance along the face's axis,
// lim: the depth test (stored near/z beyond it = something nearer the light), lf: the face's focal length (texels).
// 1. the blockers round the point, averaged; 2. the penumbra they cast here, from the light's size; 3. that many texels
// filtered, a rotated Poisson disc (rotated per pixel, so no banding). Samples stay inside the face (its margin).
const vec2 POIS[16] = vec2[16](vec2(-0.94, -0.40), vec2(0.95, -0.77), vec2(-0.09, -0.93), vec2(0.34, 0.29), vec2(-0.92, 0.46), vec2(-0.82, 0.15),
    vec2(-0.38, 0.28), vec2(-0.20, -0.63), vec2(0.97, 0.18), vec2(-0.69, -0.71), vec2(0.13, 0.70), vec2(0.62, 0.78), vec2(0.54, -0.40),
    vec2(-0.47, 0.88), vec2(0.27, -0.25), vec2(0.70, -0.01));
float pcss(sampler2D m, ivec2 o, vec2 lo, vec2 hi, vec2 s, float lz, float lim, float lf, float size);
float pcssTile(sampler2D m, ivec2 o, float fsz, vec2 s, float lz, float lim, float lf) { return pcss(m, o, vec2(1.0), vec2(fsz - 3.0), s, lz, lim, lf, uLightSoft); }
// the same on a whole map (the flashlight's pair): outside it, no shadow (as softAt's -1)
float pcssMap(sampler2D m, ivec2 sz, vec2 s, float lz, float lim, float lf, float size) {
    if (s.x < 1.0 || s.y < 1.0 || s.x > float(sz.x) - 3.0 || s.y > float(sz.y) - 3.0) return 0.0;
    return pcss(m, ivec2(0), vec2(1.0), vec2(sz) - 3.0, s, lz, lim, lf, size);
}
float pcss(sampler2D m, ivec2 o, vec2 lo, vec2 hi, vec2 s, float lz, float lim, float lf, float size) {
    float a = 6.2832 * fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    mat2 rot = mat2(cos(a), sin(a), -sin(a), cos(a));
    // 1. blockers: within the light's own size as seen from here, at most uSoftMax texels
    float sr = clamp(size * lf / max(lz, 1.0), 1.5, uSoftMax), zb = 0.0, nb = 0.0;
    for (int i = 0; i < 16; i++) {
        vec2 q = clamp(s + rot * POIS[i] * sr, lo, hi);
        float d = texelFetch(m, o + ivec2(q), 0).r;
        if (d > lim) { zb += uNear / d; nb += 1.0; }
    }
    if (nb < 0.5) return 0.0;                                   // nothing in the way
    zb /= nb;
    // 2. the penumbra here: the light's width x how far the shadow fell past its blocker, over the blocker's distance
    float pr = clamp(size * (lz - zb) / max(zb, 1.0) * lf / max(lz, 1.0) * 0.5, 0.75, uSoftMax);
    // 3. filtered over it
    float sum = 0.0;
    for (int i = 0; i < 16; i++) sum += tapO(m, o, clamp(s + rot * POIS[i] * pr, lo, hi), lim);
    return sum / 16.0;
}
void main() {
    // a re-laid face ping-pongs inside its part of the texture (vRange); the slopes are taken unfolded and turned with the
    // mirror, so the copies and the relief's directions stay right across each fold
    vec2 uvF = vUv, sg = vec2(1.0);
    if ((vFix & 1) != 0) { float t = mod((uvF.x - vRange.x) / vRange.z, 2.0); sg.x = t > 1.0 ? -1.0 : 1.0; uvF.x = vRange.x + (t > 1.0 ? 2.0 - t : t) * vRange.z; }
    if ((vFix & 2) != 0) { float t = mod((uvF.y - vRange.y) / vRange.w, 2.0); sg.y = t > 1.0 ? -1.0 : 1.0; uvF.y = vRange.y + (t > 1.0 ? 2.0 - t : t) * vRange.w; }
    vec2 st = vec2(uvF.x, uFlip > 0.5 ? 1.0 - uvF.y : uvF.y), stU = vec2(vUv.x, uFlip > 0.5 ? 1.0 - vUv.y : vUv.y);
    vec2 gx = dFdx(stU) * sg, gy = dFdy(stU) * sg;          // (taken before any pixel can be discarded)
    float fwW = max(length(dFdx(vWorld)), length(dFdy(vWorld))) + 1e-6;     // world units per pixel (the water's caustics)
    vec3 pq1 = dFdx(vView), pq2 = dFdy(vView);
    vec3 baryW = max(fwidth(vBary), vec3(1e-5));             // (the outlines' width in pixels: taken before any discard)
    // PARALLAX DEPTH: the view ray stepped into the height map from where it meets the face, the texture read where it meets
    // the sunken surface (between the last two steps) -- mortar, plank gaps and stone joints sit below the face and shift as
    // you move. The face's texture directions in the world come from how st runs across the screen (as the relief's).
    float pomD = uPomOn != 0 && (vFix & 12) == 0 ? uPom.x * uPomK * uRelief * uReliefK * (1.0 - smoothstep(uPom.y * 0.5, uPom.y, vView.z)) : 0.0;      // (and fading out at glancing views: below)
    if (pomD > 0.001) {
        vec3 Nf = normalize(vTri.yzw), Vv = normalize(-vView); if (dot(Nf, Vv) < 0.0) Nf = -Nf;
        vec3 q2p = cross(pq2, Nf), q1p = cross(Nf, pq1); float det = dot(pq1, q2p);
        if (abs(det) > 1e-20) {
            vec3 gu = (q2p * gx.x + q1p * gy.x) / det, gv = (q2p * gx.y + q1p * gy.y) / det;      // st per world unit, along the face
            float vn = dot(Vv, Nf); vec3 vt = Vv - Nf * vn; pomD *= smoothstep(0.12, 0.4, vn);      // (at a glance the offsets run away: a smear)
            vec2 full = -vec2(dot(vt, gu), dot(vt, gv)) / max(vn, 0.3) * pomD;                    // st moved at the full depth
            int n = int(mix(uPom.z, uPom.z * 0.35, vn));
            float dl = 1.0 / float(n), layer = 0.0; vec2 duv = full * dl, p = st;
            float d = 1.0 - textureGrad(uHeight, p, gx, gy).r, dPrev = d;
            for (int i = 0; i < 64; i++) {
                if (i >= n || layer >= d) break;
                p += duv; layer += dl; dPrev = d; d = 1.0 - textureGrad(uHeight, p, gx, gy).r;
            }
            float fa = dPrev - (layer - dl), fb = d - layer;
            if (layer > 0.0 && fa - fb > 1e-5) p -= duv * (1.0 - clamp(fa / (fa - fb), 0.0, 1.0));
            st = p;
        }
    }
    bool glassPx = false;
    if (texture(uMask, st).r < 0.5 / 255.0) { if (uGlass <= 0.0) discard; glassPx = true; }        // palette index 0: a hole in the texture (or a pane: uGlass)
    float artK = uArtOn != 0 ? artAt(st) : 1.0;
    if (uRelayDebug != 0 && (vFix & 28) != 0) { oColor = (vFix & 64) != 0 ? vec4(1.0, 0.0, 1.0, 1.0) : vec4((vFix & 48) == 16 ? 1.0 : 0.0, (vFix & 12) != 0 ? 1.0 : 0.0, (vFix & 32) != 0 ? 1.0 : 0.0, 1.0); return; }
    // the mix against repeats: which of eight shifts (only along the ways the surface repeats), from slow noise over the tiles
    float mixF = -1.0;
    if (uMixOn != 0 && (vFix & 12) != 0) {
        vec2 ax = vec2((vFix & 4) != 0 ? 1.0 : 0.0, (vFix & 8) != 0 ? 1.0 : 0.0);
        float n = clamp(noised(vec3(st * uMixScale, 3.7)).x * 0.75 + 0.5, 0.0, 0.999) * 8.0, ia = floor(n);
        uvec3 ha = pcg3d(uvec3(uint(ia), 17u, 5u)), hb = pcg3d(uvec3(uint(ia) + 1u, 17u, 5u));
        gMixA = vec2(ha.xy >> 8u) * (1.0 / 16777216.0) * ax; gMixB = vec2(hb.xy >> 8u) * (1.0 / 16777216.0) * ax;
        mixF = n - ia;
    }
    if (uRefl != 0) {
        float sd = texelFetch(uSurf, ivec2(gl_FragCoord.xy), 0).r;
        if (gl_FragCoord.z >= sd * 0.998) discard;          // not beyond the water's surface
    }
    float w = vView.z;
    // which copies of the texture: the face's density plus this pixel's depth, blended between two
    float lod = vLod + log2(max(1.0, w));
    vec4 tex4 = fetchMix(uTex, st, gx * uMipK, gy * uMipK, max(lod, 0.0), 1.0, uPixelMip != 0);
    if (mixF >= 0.0) {
        // the second shift, blended where the noise crosses over -- sooner where the two copies already look alike
        vec4 c1 = uPixelMip != 0 ? textureGrad(uTex, st + gMixB, gx * uMipK, gy * uMipK) : textureLod(uTex, st + gMixB, max(lod, 0.0));
        gMixT = smoothstep(0.3, 0.7, mixF - 0.15 * dot(tex4.rgb - c1.rgb, vec3(1.0)));
        tex4 = mix(tex4, c1, gMixT);
    }
    vec3 tex = tex4.rgb * 255.0;
    // GLASS (see uGlass): the pane at its share of its own colour, in the light behind it, unlit by the room; it shows
    // through the fog as a lit surface does
    if (glassPx) { oColor = vec4(min(tex * uGlassTint * uGlass, vec3(255.0)) / 255.0, uRefl != 0 ? 0.0 : 0.8); return; }
    // RELIEF. The face's own normal, turned toward the eye; then bent by the bump map in the
    // face's texture directions (worked out from how the texture runs across the screen).
    vec3 N = normalize(vTri.yzw), Vd = normalize(-vView);
    if (dot(N, Vd) < 0.0) N = -N;
    float scGlow = 0.0;
    if (uScN > 0 && uRefl == 0) {
        vec3 nwS = transpose(mat3(uView)) * N; float scDark = 0.0;
        for (int i = 0; i < 16; i++) {
            if (i >= uScN) break;
            vec3 d = vWorld - uScP[i].xyz; float r = uScP[i].w;
            if (dot(d, d) > r * r * 2.0 || dot(nwS, uScQ[i].xyz) < 0.6 || abs(dot(d, uScQ[i].xyz)) > 3.0) continue;
            float age = uScQ[i].w, fade = 1.0 - smoothstep(uScLife * 0.4, uScLife, age);
            vec3 dd = d - uScQ[i].xyz * dot(d, uScQ[i].xyz);
            float nz = noised(vWorld * 0.45 + vec3(float(i) * 7.1)).x;
            float rr = length(dd) / (r * (0.8 + 0.45 * nz));
            scDark = max(scDark, (1.0 - smoothstep(0.25, 1.0, rr)) * fade * 0.82);
            scGlow += (1.0 - smoothstep(0.0, 0.5, rr)) * exp(-age / 0.6);
        }
        tex *= 1.0 - scDark;
    }
    vec3 Np = N; float reliefK = 1.0, cavK = 1.0;
    float relK = uRelief * uReliefK;                        // (none on a shiny surface: see uReliefK)
    if (relK > 0.0) {
        vec2 sn = st * uNormTile; float kn = uNormMipK * uNormTile;
        vec4 nm = fetchMix(uNorm, sn, gx * kn, gy * kn, max(lod + uNormLod + log2(uNormTile), 0.0), uNormTile, uPixelMip != 0);
        vec3 nt;
        if (uNormBands != 0) {
            // each layer back to a slope (a normal's x,y over its z), mixed, and made a normal again
            vec2 f = nm.xy * 2.0 - 1.0, m = nm.zw * 2.0 - 1.0;
            vec2 s = f / max(sqrt(max(1.0 - dot(f, f), 0.0)), 0.05) * uNormFine + m / max(sqrt(max(1.0 - dot(m, m), 0.0)), 0.05) * uNormMid;
            nt = normalize(vec3(s, 1.0));
        } else {
            vec2 nxy = nm.xy * 2.0 - 1.0;
            nt = vec3(nxy, sqrt(max(1.0 - dot(nxy, nxy), 0.0)));
        }
        vec3 dp1 = dFdx(vView), dp2 = dFdy(vView); vec2 du1 = gx, du2 = gy;
        vec3 dp2perp = cross(dp2, N), dp1perp = cross(N, dp1);
        vec3 T = dp2perp * du1.x + dp1perp * du2.x, B = dp2perp * du1.y + dp1perp * du2.y;
        float mx = max(dot(T, T), dot(B, B));
        if (mx > 1e-30) { float im = inversesqrt(mx); Np = normalize((T * nt.x + B * nt.y) * im * relK + N * max(nt.z, 0.2)); }
        // MICRO RELIEF over that: layers of noise in the world, coarse to fine, each half the size of the last and
        // turned so no grid lines up with the walls. Each layer's slope is kept the same whatever its size
        // (height = amplitude x size), and it fades out as its bumps near two pixels across -- detail up close, no
        // shimmer far off. The slope is laid along the surface (its part across the surface removed) and bends Np.
        if (uDetail > 0.0) {
            float fw = max(length(dFdx(vWorld)), length(dFdy(vWorld))) + 1e-6;     // world units per pixel, here
            mat3 R = mat3(1.0), M = mat3(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64);
            vec3 gs = vec3(0.0); float hs = 0.0, amp = 1.0, size = uDetailScale;
            for (int o = 0; o < 6; o++) {
                if (o >= uDetailOct) break;
                float k = smoothstep(2.0, 5.0, size / fw);
                if (k <= 0.0) break;                                  // (finer layers only get smaller)
                vec4 n = noised(R * (vWorld / size) + vec3(float(o) * 17.13));
                gs += transpose(R) * n.yzw * (amp * k); hs += n.x * amp * k;
                R = M * R; amp *= uDetailRough; size *= 0.5;
            }
            vec3 gv = mat3(uView) * gs * (uDetail * uReliefK);
            Np = normalize(Np - (gv - dot(gv, Np) * Np));
            cavK = 1.0 - uReliefOp * uDetailAO * uReliefK * clamp(-hs * 1.5, 0.0, 1.0);    // the hollows a shade darker (tinted below)
            tex *= cavK;
        }
        // the lamp sits at the eye: how much more (or less) squarely this pixel faces it than the face does
        float fG = abs(dot(N, Vd)), fP = max(dot(Np, Vd), 0.0);
        reliefK = (0.1 + 0.9 * fP) / (0.1 + 0.9 * fG);
        // (on a floor seen at a glancing angle fG is small, so a bump tipped toward the lamp came out up to ~3.5x as
        // bright: white blobs that read as BIG bumps. Capped, both ways: uReliefGain = the most it may brighten)
        reliefK = clamp(reliefK, 1.0 / uReliefGain, uReliefGain);
        // THE RELIEF'S OPACITY (Josh, 2026-10-07: 'lets try at 80% opacity'), as a layer's: the lamp's light is linear in
        // reliefK, so mixing it with 1 IS mixing the relief-lit picture with the flat one; the torches use a normal
        // mixed the same way, and the hollows (cavK, above) and the shadow tint (below, from g / gFlat) follow.
        reliefK = mix(1.0, reliefK, uReliefOp);
        Np = normalize(mix(N, Np, uReliefOp));
    }
    // HOW WET THIS IS (see uWetOn): 0..1, and how much of it is a puddle (a mirror-flat film)
    float wet = 0.0, puddle = 0.0;
    if (uWetOn != 0 && uRefl == 0 && uWetK > 0.0) {
        vec3 nw = transpose(mat3(uView)) * N;               // the face's normal in the room (its side toward the eye)
        float up = nw.y;
        if (up > 0.6) {
            // a floor: damp all over, puddles where low noise is high (two sizes, so their edges are not round) -- only on
            // LEVEL floor: water does not lie on a slope (Josh: on CORICORI's slanting tiles 'the puddles defy gravity')
            if (uWetB.z > 0.0 && up > 0.975) {
                float pn = noised(vec3(vWorld.xz / max(uWetB.w, 1.0), 3.7)).x * 0.75 + noised(vec3(vWorld.xz / max(uWetB.w * 0.35, 1.0), 9.1)).x * 0.25;
                float th = 0.32 * (0.5 - uWetB.z);
                puddle = smoothstep(th, th + 0.035, pn) * smoothstep(0.975, 0.993, up);
            }
            wet = max(uWetA.w, puddle);
        } else if (up < -0.5) {
            wet = uWetC.y;                                  // a ceiling
        } else {
            // a wall (or a slope): damp from the floor beneath it up to a ragged line
            float gy = groundAt(vWorld.xz + nw.xz * 6.0);
            float h = (vWorld.y - gy) / max(uWetA.y, 1.0);
            // (the ragged line only where it can fall: the noise moves it at most 0.45 either way)
            if (h <= 0.0) wet = 1.0;
            else if (h < 1.45) wet = 1.0 - smoothstep(0.45, 1.0, h + noised(vWorld * 0.05 + vec3(5.3)).x * 0.5 + noised(vWorld * 0.17).x * 0.15);
            wet *= uWetC.x;                                 // (the walls' share: a cave's half)
        }
        // THE ART'S DARK PARTS STAY DRY (Josh, 2026-10-12, CORICORI: 'some of the wet effect is on black portions of the textures,
        // which kind of goes against the artwork ... map out the dark portions of the texture and have the wet areas fade into the
        // darkness'): a coarse copy of the texture (about 64 texels across, whatever its size) maps where its art is painted
        // dark, and the wet fades out into it (uWetC.z -> .w); a texel painted black on its own takes none either
        {
            vec2 tz = vec2(textureSize(uTex, 0));
            float lcoarse = dot(textureLod(uTex, st, max(0.0, log2(max(tz.x, tz.y) / 64.0))).rgb * 255.0, vec3(0.30, 0.59, 0.11));
            float lhere = dot(tex, vec3(0.30, 0.59, 0.11));
            float lit = smoothstep(uWetC.z, max(uWetC.w, uWetC.z + 1.0), lcoarse) * smoothstep(2.0, 12.0, lhere);
            wet *= lit; puddle *= lit;
        }
        float k = uWetA.x * uWetK;
        wet = clamp(wet * k, 0.0, 1.0); puddle = clamp(puddle * k, 0.0, 1.0);
        if (uWetDebug != 0) { float hd = (vWorld.y - groundAt(vWorld.xz + nw.xz * 6.0)) / max(uWetA.y, 1.0); oColor = vec4(wet, puddle, clamp(hd * 0.5, 0.0, 1.0), 1.0); return; }
        // darker and a little richer where wet (it soaks in), darker still under standing water
        float lw = dot(tex, vec3(0.30, 0.59, 0.11));
        tex = max(mix(vec3(lw), tex, 1.0 + 0.25 * wet), vec3(0.0)) * (mix(1.0, uWetA.z, wet) * (1.0 - 0.18 * puddle));
    }
    vec3 Ns = Np;                                           // (the normal the highlights see: a water film fills the bumps; a puddle is flat)
    if (wet > 0.0) Ns = normalize(mix(Np, N, clamp(0.3 * wet + puddle, 0.0, 1.0)));
    // THE SHINE HERE: the material's strength, shaped per texel by the companion smoothness map -- or, without one, by the
    // art itself: brighter than its surroundings (a coarser copy of the same texture) shines more, painted dark does not
    float shineK = 0.0, glossK = max(uGloss, 1.0), glowK = 0.0;
    if (uShineOn != 0 && uRefl == 0 && (uShine > 0.0 || uMatHas != 0 || wet > 0.0)) {
        vec4 mt = vec4(0.5, 0.5, 0.0, 1.0);
        if (uMatHas != 0) mt = fetchMix(uMat, st, gx * uMipK, gy * uMipK, max(lod, 0.0), 1.0, uPixelMip != 0);
        if ((uMatHas & 1) != 0) {
            shineK = uShine * 2.0 * mt.r; glossK = max(uGloss * exp2(3.0 * (mt.r - 0.5)), 1.0);
        } else if (uShine > 0.0) {
            float lc = dot(tex, vec3(0.30, 0.59, 0.11));
            vec2 tsz = vec2(textureSize(uTex, 0));      // (the level from this pixel's own slopes, taken before any discard)
            float lq = (uPixelMip != 0 ? max(log2(max(max(length(gx * tsz), length(gy * tsz)), 1e-6)), 0.0) : max(lod, 0.0)) + 4.0;
            float lm = dot(textureLod(uTex, st, lq).rgb * 255.0, vec3(0.30, 0.59, 0.11));
            shineK = uShine * clamp(1.0 + uShineVary * (lc - lm) / max(lm, 12.0), 0.0, 2.5) * smoothstep(3.0, 24.0, lc);
        }
        if ((uMatHas & 4) != 0) glowK = mt.b;
        // a film of water over it: more shine and a tighter highlight -- a puddle much tighter
        if (wet > 0.0) {
            shineK = mix(shineK, uWetB.x * (1.0 + 5.0 * puddle), wet);
            glossK = mix(glossK, uWetB.y * (1.0 + 5.0 * puddle), wet);
        }
    }
    float specL = 0.0; vec3 specC = vec3(0.0);      // (the lamp's highlight, and the placed lights' in their colours)
    // the room's level plus the lamp: cone by angle off the beam's centre, falloff by depth
    float g = 1.0, gFlat = 1.0, occF = 0.0, roomPart = 0.0;
    if (uLampOn != 0) {
        vec2 d = gl_FragCoord.xy - uLampC;
        float tan2 = min(dot(d, d) / (uFpx * uFpx), 2.0);
        float cs = inversesqrt(1.0 + tan2);
        float t = soft((cs - uCones.y) / (uCones.x - uCones.y));
        float h = soft((cs - uCones.w) / (uCones.z - uCones.w));
        float rest = max(0.0, 1.0 - uSpill - uHalo);
        float cone = uSpill + uHalo * h + rest * t;
        float wc = min(w, 2046.0), dd = wc / uLampRange;
        float lampF = cone / (1.0 + dd * dd), baseK = 1.0;
        if (uRefl == 0 && uLampMaps > 0) {
            // where this pixel is in the lamp's view: (x/z)_lamp = (x/z)_eye - offset * (1/z)
            float iz = 1.0 / w, lim = iz * uShadow.x * uNear;
            float ex = (gl_FragCoord.x - uCentre.x) / uFpx, ey = (uCentre.y - gl_FragCoord.y) / uFpx;
            float occ = 0.0;
            for (int i = 0; i < uLampMaps; i++) {
                vec2 s = vec2((ex - uLampOff[i].x * iz) * uLampMapF.x + uLampMapF.y, uLampMapF.z - (ey - uLampOff[i].y * iz) * uLampMapF.x);
                occ += uLampSoft > 0.0 ? pcssMap(uLampMap[i], uLampMapSize, s, w, lim, uLampMapF.x, uLampSoft)      // soft contact (2026-10-08)
                                       : max(softAt(uLampMap[i], uLampMapSize, s, lim, uShadow.y), 0.0);
            }
            occ /= float(uLampMaps);
            if (occ > 0.0) {
                occ *= soft((uSFade.x - wc) * uSFade.y);     // thinner with distance from the player
                occF = occ;                                   // (the muzzle flash, from about the same place, is shadowed alike)
                lampF *= 1.0 - occ;                           // the lamp does not reach
                baseK = 1.0 - uShadow.z * occ;                // and the shadow is darker than the room
            }
        }
        // its highlight: Blinn, toward the lamp from the bent surface (the pair's middle, just above the eye)
        if (shineK > 0.0 && lampF > 0.0) {
            vec3 Ls = normalize(uLampPos - vView), Hs = normalize(Ls + Vd);
            specL = uLampPower * lampF * pow(max(dot(Ns, Hs), 0.0), glossK) * (glossK + 2.0) * 0.125 * max(dot(Ns, Ls), 0.0);
        }
        float roomK = uLampRoom * (uGiOn != 0 ? uGiAmb : 1.0) * artK;      // (the reflection too: it shows the same room)
        g = roomK * baseK + vTri.x * reliefK * uLampPower * lampF;
        gFlat = roomK * baseK + vTri.x * uLampPower * lampF;       // the same light with the surface left flat
        roomPart = roomK * baseK;
    }
    if (uRefl != 0) { g *= uDim; roomPart *= uDim; }
    vec3 gain = vec3(g) + (uRoomTint - 1.0) * roomPart;      // (the room's level in its colour; the lamp stays white)
    // in a reflection in water, the bounced light of the real point this mirrors (uMirY: the water's height)
    if (uGiOn != 0 && uRefl != 0) {
        vec3 nr = transpose(mat3(uView)) * Np; nr.y = -nr.y;
        gain += uDim * uGiK * artK * giAt(vec3(vWorld.x, 2.0 * uMirY - vWorld.y, vWorld.z), nr);
    }
    if (uFlash > 0.0 && uRefl == 0) {
        float df = min(w, 2046.0) / uFlashRange;
        gain += uFlashC * (uFlash * vTri.x * reliefK * (1.0 - occF) / (1.0 + df * df));
    }
    vec3 lightG = vec3(0.0);      // (the placed lights' share of this pixel's light: into alpha, for the fog -- see uVolLit)
    if (uRefl == 0) {
        float sAmb = 0.0;       // how deep in a placed light's shadow this pixel is, weighted by that light's share of it
        for (int i = 0; i < uLightCount; i++) {
            vec3 dl = uLightP[i].xyz - vView;
            float d2 = max(dot(dl, dl), 1.0);
            // facing the light, with relief: the bent normal on the light's side of the face
            float sideL = dot(dl, N) >= 0.0 ? 1.0 : -1.0;
            float facingL = relK > 0.0 ? max(dot(dl, Np) * sideL, 0.0) : abs(dot(dl, vTri.yzw));
            // (w below 0: a ONE-SIDED light -- SetLightOneSided -- lights only the side of a face the eye is on, so sunlight
            // behind a wall does not light its inner face: BAPTIST's windows, 2026-10-14)
            float att = facingL / (sqrt(d2) * (1.0 + d2 * abs(uLightP[i].w)));
            if (uLightP[i].w < 0.0 && sideL < 0.0) att = 0.0;
            if (uGateLo[i].w > 0.5 && att > 0.0 && !segThrough(uLightW[i], vWorld, uGateLo[i].xyz, uGateHi[i])) att = 0.0;
            if (uLightCone[i].y > -1.5) att *= soft((dot(-dl, uLightDir[i]) * inversesqrt(d2) - uLightCone[i].y) / max(uLightCone[i].x - uLightCone[i].y, 1e-3));
            // (no light reaching here -- facing away, or outside a spot's cone: its shadow could change nothing, so its map is
            // not read -- 2026-10-13 performance audit; att >= 0 and sAmb only rises, so the result is the same)
            if (uLightMapOn[i] != 0 && att > 0.0) {
                // from the light to this pixel, in the light view's own axes
                vec3 q = -dl;
                float ol = -1.0;
                if (uLightMapOn[i] == 2) {
                    // ALL ROUND (Josh, 2026-10-08: a single 110-degree view cut the player's shadow off in a straight line
                    // wherever it left that view): the face this direction falls in, the one whose forward it is nearest
                    int fb = 0; float lz = dot(q, uCubeAx[0][2]);
                    for (int f = 1; f < 6; f++) { float z = dot(q, uCubeAx[f][2]); if (z > lz) { lz = z; fb = f; } }
                    if (lz > 0.5) {
                        float lf = uLightMapF[i].x, fsz = uLightMapF[i].y, hs = fsz * 0.5;
                        vec2 s = vec2(dot(q, uCubeAx[fb][0]) / lz * lf + hs, hs - dot(q, uCubeAx[fb][1]) / lz * lf);
                        float lim = (1.0 / lz) * uShadow.w * uNear;
                        ol = uLightSoft > 0.0 ? pcssTile(uLightMap[i], ivec2(fb % 3, fb / 3) * int(fsz), fsz, s, lz, lim, lf)
                                              : softTile(uLightMap[i], ivec2(fb % 3, fb / 3) * int(fsz), fsz, s, lim, uShadow.y);
                    }
                } else {
                    float lz = dot(q, uLightAx[i][2]);
                    if (lz > 0.5) {
                        float lf = uLightMapF[i].x, hs = uLightMapF[i].y * 0.5;
                        vec2 s = vec2(dot(q, uLightAx[i][0]) / lz * lf + hs, hs - dot(q, uLightAx[i][1]) / lz * lf);
                        int sz = int(uLightMapF[i].y);
                        ol = softAt(uLightMap[i], ivec2(sz, sz), s, (1.0 / lz) * uShadow.w * uNear, uShadow.y);
                    }
                }
                {
                    if (ol > 0.0) {
                        float c = dot(uLightC[i], vec3(0.3333)) * att;
                        sAmb = max(sAmb, ol * c / (c + g + 1e-4));
                        att *= 1.0 - ol;
                    }
                }
            }
            vec3 lc = uLightC[i] * mix(vec3(1.0), uLightTintM[i], smoothstep(uLightTintD[i].x, uLightTintD[i].y, sqrt(d2))) * att;
            gain += lc; lightG += lc * (uLightCone[i].y > -1.5 ? 1.0 : exp(-d2 * uLitR));      // (all round: only near it, as the flashlight's cone; a spot: in its beam)
            // its highlight, in its own colour (att already holds the facing, the distance and the shadow)
            if (shineK > 0.0 && att > 0.0) {
                vec3 Hl = normalize(dl * inversesqrt(d2) + Vd);
                specC += lc * (pow(max(dot(Ns, Hl), 0.0), glossK) * (glossK + 2.0) * 0.125);
            }
        }
        // THE WALL WASHES (see uWashN): as a placed spotlight, without a shadow
        for (int i = 0; i < uWashN; i++) {
            vec3 dl = uWashP[i].xyz - vView;
            float d2 = max(dot(dl, dl), 1.0);
            float sideL = dot(dl, N) >= 0.0 ? 1.0 : -1.0;
            // (a wash grazes its wall: the full relief there turned the stone to speckle -- 40% of it)
            float facingL = relK > 0.0 ? max(dot(dl, normalize(mix(N, Np, 0.4))) * sideL, 0.0) : abs(dot(dl, vTri.yzw));
            float att = facingL / (sqrt(d2) * (1.0 + d2 * uWashP[i].w));
            att *= soft((dot(-dl, uWashDir[i]) * inversesqrt(d2) - uWashCone[i].y) / max(uWashCone[i].x - uWashCone[i].y, 1e-3));
            if (att <= 0.0) continue;
            vec3 lc = uWashC[i] * att;
            gain += lc; lightG += lc;
            if (shineK > 0.0) {
                vec3 Hl = normalize(dl * inversesqrt(d2) + Vd);
                specC += lc * (pow(max(dot(Ns, Hl), 0.0), glossK) * (glossK + 2.0) * 0.125);
            }
        }
        // DEEPER SHADOWS (Josh, 2026-10-07: 'a touch darker'): a placed light's shadow also takes some of the room's
        // own level, as much as that light dominates there -- so it never darkens where the light hardly reached,
        // and the flashlight still fills it (the lamp raises g, which shrinks the light's share)
        gain -= vec3(g) * (uLightDeep * sAmb);
        // BOUNCED LIGHT: what the placed lights throw off every other surface, worked out once per room (GiBake)
        if (uGiOn != 0) gain += uGiK * artK * giAt(vWorld, transpose(mat3(uView)) * Np);
        // GLOWING WATER: the light out of each pool below this pixel (see uWN)
        if (uWN > 0) {
            vec3 nw = transpose(mat3(uView)) * N;                 // the face's normal in the room (its side toward the eye)
            float face = clamp(0.8 - nw.y, 0.0, 1.0);             // walls and undersides take it; floors and tops do not
            for (int i = 0; i < 4; i++) {
                if (i >= uWN) break;
                float h = vWorld.y - uWY[i];
                if (face <= 0.0 || h < -1.0 || h > uCaus.w * 5.0) continue;
                vec2 lo = uWBox[i].xy, hi = uWBox[i].zw;
                vec2 o = max(max(lo - vWorld.xz, vWorld.xz - hi), 0.0);
                float edge = 1.0 - soft(length(o) / max(uCaus.w * 0.5, 1.0));
                if (edge <= 0.0) continue;
                float fall = exp(-max(h, 0.0) / uCaus.w) * edge * face;
                for (int k = 0; k < 4; k++) {
                    if (k >= uWCutN) break;
                    vec2 oc = max(max(uWCut[k].xy - vWorld.xz, vWorld.xz - uWCut[k].zw), 0.0);      // 0 inside the box
                    fall *= soft(length(oc) / 12.0);                                                // (a 12-unit soft edge outside it)
                }
                // the pattern laid along the surface: a wall by (along it, height -- squashed, so the lines run level),
                // anything else by the floor plan
                vec2 pl = abs(nw.y) > 0.7 ? vWorld.xz : (abs(nw.x) > abs(nw.z) ? vec2(vWorld.z, vWorld.y * 1.6) : vec2(vWorld.x, vWorld.y * 1.6));
                float c = caustic(pl, uTime, uCaus.y, uCaus.z, fwW);
                // (paler than the water's own colour: the light that reaches the walls is mostly the lamps'; full cyan turned the brown stone green)
                gain += mix(uGlowCol, vec3(1.0), 0.4) * (glowAt(clamp(vWorld.xz, lo, hi)) * fall * (uCausFill + uCaus.x * c));
            }
        }
    }
    vec3 col = tex * gain;
    // RELIEF SHADOWS IN THE TEXTURE'S OWN COLOUR (Josh, 2026-10-07: the relief's 'dark gray shadows ... feel muddy';
    // 'like a multiply layer in photoshop'). Where the relief (or the micro relief's hollows) darkens a pixel, it is
    // darkened the way multiplying the texture by itself would: its weaker channels drop further than its strongest,
    // so the shadow is a deeper version of the stone's own hue, not a greyer one. Same brightness as before (the tint
    // is scaled to keep luminance); the deeper the relief's shadow, the stronger. Lit bumps are left as they were.
    if (uReliefTint > 0.0) {
        float shade = clamp(g / max(gFlat, 1e-3), 0.0, 1.0) * cavK;     // 1 = untouched, lower = in a relief shadow
        float q = uReliefTint * (1.0 - shade);
        if (q > 0.001) {
            vec3 cn = max(tex / max(max(tex.r, max(tex.g, tex.b)), 1.0), vec3(0.002));
            vec3 tq = pow(cn, vec3(q));
            col *= tq / max(dot(tq, vec3(0.30, 0.59, 0.11)), 1e-3);
        }
    }
    // THE HIGHLIGHTS, over that: the light's own colour on a non-metal (a little more at a grazing angle, as wet floors and
    // polished stone show), the surface's own colour on a metal (gold glints gold)
    if (shineK > 0.0) {
        vec3 hue = tex / max(max(tex.r, max(tex.g, tex.b)), 1.0);
        float fres = mix(1.0 + 2.0 * pow(1.0 - max(dot(Ns, Vd), 0.0), 5.0), 1.0, uMetal);
        vec3 hl = (specL * vec3(1.0, 0.97, 0.92) + specC) * mix(vec3(1.0), hue, uMetal) * (255.0 * shineK * fres);
        // a wet film's glints are bright but never a white blob: a flat wet door square to the lamp tops out at a sheen
        // (softly, at ~uWetA's limit); standing water is a mirror and is not held back
        // (held by its brightness, keeping its colour: a torch beside a wet wall is a warm sheen, not a pale wash)
        if (wet > 0.0) {
            float lim = mix(4096.0, 80.0, wet * (1.0 - puddle)), lh = dot(hl, vec3(0.30, 0.59, 0.11));
            if (lh > 1e-3) hl *= lim * (1.0 - exp(-lh / lim)) / lh;
        }
        col += hl;
        // a PUDDLE mirrors the room a little: the bounced light coming from where its reflection points, by the angle
        if (puddle > 0.0 && uGiOn != 0) {
            vec3 Rw = transpose(mat3(uView)) * reflect(-Vd, N);
            float fr = 0.04 + 0.96 * pow(1.0 - max(dot(N, Vd), 0.0), 5.0);
            col += uGiK * giAt(vWorld, Rw) * (255.0 * 0.6 * fr * puddle);
        }
    }
    // what GLOWS (a companion glow map): at least its own painted colour, whatever the light
    if (glowK > 0.0) col = max(col, tex * (uGlowK * glowK));
    if (scGlow > 0.0) { col += vec3(255.0, 130.0, 45.0) * min(scGlow, 1.2); lightG += vec3(min(scGlow, 1.0)); }
    // THE ECHO'S SHELL passing over the room: a bright amber front with fine contour rings trailing it (a sonar's sweep)
    if (uEcho.z > 0.0 && uRefl == 0) {
        float dd = length(vView), x = (uEcho.x - dd) / max(uEcho.y, 1.0);
        if (x > -1.5 && x < 6.0) {
            float frontE = exp(-x * x * 2.0), trailE = x > 0.0 ? exp(-x / 2.2) * (0.5 + 0.5 * smoothstep(0.82, 1.0, abs(fract(dd / 9.0) * 2.0 - 1.0))) : 0.0;
            float eg = uEcho.z * (frontE + 0.28 * trailE);
            col += vec3(255.0, 150.0, 50.0) * eg * 0.55; lightG += vec3(eg * 0.7);
        }
    }      // (a fresh scorch's ember-hot middle -- through the dark air, as a light's)
    col = min(col, vec3(255.0));
    if (uFogOn != 0 && uRefl == 0) {
        float ff = soft((w - uFog.x) * uFog.y) * uFog.z;
        col += (uFogCol - col) * ff;
    }
    // THE VISOR MATERIALIZES THE ROOM (Josh, 2026-10-13): the WIRE front draws the polygons' outlines outward over dark glass
    // (flaring as it passes); the TEXTURE front follows, the surface coming up in full under a soft band of light; behind it
    // the outlines linger and fade (uMatX.y seconds), and specks of light twinkle about both fronts and in the trail.
    if (uMatz.w > 0.5 && uRefl == 0) {
        float d = length(vView), band = uMatz.y;
        float behindT = uMatz.x - d, behindW = uMatz.z - d;
        vec3 eb = smoothstep(vec3(0.0), baryW * 1.5, vBary);
        float edge = 1.0 - min(min(eb.x, eb.y), eb.z);
        float drawn = smoothstep(-0.3 * band, 0.3 * band, behindW);
        float wireHot = exp(-abs(behindW) / (0.45 * band));
        float reveal = smoothstep(-0.25 * band, 1.4 * band, behindT);
        float front = exp(-abs(behindT) / (0.6 * band));
        float trail = behindT > 0.0 ? 1.0 - smoothstep(0.35, 1.0, behindT / (uMatX.z * uMatX.y)) : 0.0;      // (the lines recede along the path, just behind the texture front)
        float lines = drawn * (mix(0.55, 1.0, max(wireHot, front)) * (1.0 - reveal) + max(front, 0.75 * trail) * reveal);
        col = col * reveal + uMatC * (0.022 * drawn * (1.0 - reveal));
        col += uMatC * (edge * lines) + uMatF * (edge * (0.85 * front + 0.5 * wireHot * drawn)) + uMatC * (0.12 * front + 0.035 * trail);
        // the specks: one pixel in each 3 x 3 cell lights, at random, re-drawn 12 times a second; densest at the fronts
        vec2 cell = floor(gl_FragCoord.xy / 3.0), inC = gl_FragCoord.xy - cell * 3.0;
        if (uMatX.w > 0.0 && all(lessThan(abs(inC - 1.5), vec2(0.6)))) {
            uvec3 hs = pcg3d(uvec3(uvec2(ivec2(cell) + ivec2(4096)), uint(uMatX.x * 12.0)));
            float hr = float(hs.x >> 8u) * (1.0 / 16777216.0), hb = float(hs.y >> 8u) * (1.0 / 16777216.0);
            float dens = uMatX.w * (0.028 * front + 0.014 * trail * (1.0 - front) + 0.012 * wireHot * drawn * (1.0 - reveal));
            if (hr < dens) col += mix(uMatC, uMatF, hb) * (0.6 + 0.6 * hb);
        }
        col = min(col, vec3(255.0));
    }    // LIT BY A PLACED LIGHT, in alpha (0..1): the compose's fog lets this much more of the surface through (uVolLit) --
    // the torches' and the shaft's light cut through the darkness from any distance, as the flashlight's does
    oColor = vec4(col / 255.0, uRefl != 0 ? 0.0 : 1.0 - exp(-2.5 * dot(lightG, vec3(0.30, 0.59, 0.11))));
}";
        // GLOWING WATER, shared by the room's shader (the light on the walls) and the water's own (needs noised, soft, and
        // the uniforms uGlowBase, uWSpotN, uWSpot)
        const string WATER_GLSL = @"
// the light coming up out of the water at (x, z): the even glow plus each lamp under it (a soft pool, radius z, strength w)
float glowAt(vec2 p) {
    float s = uGlowBase;
    for (int i = 0; i < 4; i++) {
        if (i >= uWSpotN) break;
        vec2 d = p - uWSpot[i].xy;
        s += uWSpot[i].w * exp(-dot(d, d) / max(uWSpot[i].z * uWSpot[i].z, 1.0));
    }
    return s;
}
// CAUSTICS: bright lines where gradient noise crosses zero -- two layers drifting at different speeds, on a gently warped
// plane -- so they knot into the moving web light makes through a rippled surface. fw: world units per pixel; lines too
// fine for the pixels there fade to their average (no shimmer far off).
float caustic(vec2 p, float t, float size, float speed, float fw) {
    vec2 q = p / size;
    vec4 w = noised(vec3(q * 0.5, t * speed * 0.35 + 11.0));
    q += w.yz * 0.45;
    float a = noised(vec3(q, t * speed)).x, b = noised(vec3(q * 1.63 + vec2(5.2, 1.7), t * speed * 1.27 + 4.0)).x;
    float k = clamp(size / (fw * 8.0), 0.0, 1.0);
    float ca = pow(clamp(1.0 - abs(a) * 7.0, 0.0, 1.0), 3.0), cb = pow(clamp(1.0 - abs(b) * 7.0, 0.0, 1.0), 3.0);
    return mix(0.12, ca * 0.85 + cb * 0.6, k);
}
";
        // THE WATER'S SURFACE (2026-10-08): drawn over the water's own lit texture where the water is the nearest thing.
        // Pass 0 brightens what is bright in it (the specks: picture x (1 + glow)); pass 1 adds the reflection -- read where
        // animated ripples bend it, as much as the angle makes it (Fresnel) -- glints of the flashlight and the placed lights
        // off the ripples, and the glow from under the water; the picture underneath kept by (1 - reflection share).
        const string VS_WATER = @"#version 400 core
layout(location = 0) in vec3 aPos;
uniform mat4 uView; uniform vec2 uF; uniform float uNear; uniform float uOffY;
out vec3 vWorld; out vec3 vView;
invariant gl_Position;
void main() {
    vec4 p = uView * vec4(aPos, 1.0);
    vWorld = aPos; vView = p.xyz;
    gl_Position = vec4(p.x * uF.x, -p.y * uF.y + uOffY * p.z, uNear, p.z);
}";
        const string FS_WATER = @"#version 400 core
in vec3 vWorld; in vec3 vView;
uniform mat4 uView; uniform float uTime; uniform vec3 uEye; uniform int uPass;
uniform sampler2D uReflTex;
uniform vec3 uGlowCol; uniform float uGlow, uGlowBase, uDots; uniform int uWSpotN; uniform vec4 uWSpot[4];
uniform vec4 uCaus;                 // (strength, size, speed, height: the surface uses the size and speed)
uniform vec3 uRip;                  // ripples: slope, size (world units), speed
uniform int uDropN; uniform vec4 uDrop[16]; uniform float uDropK;     // drips landing: x, z, when (uTime), the height they landed at
uniform float uShine, uF0, uSpec, uDistort, uLightSpec;
uniform int uLampOn; uniform float uLampPower, uLampRange, uFpx, uSpill, uHalo; uniform vec4 uCones; uniform vec2 uLampC;
uniform int uLightN; uniform vec4 uLightP[4]; uniform vec3 uLightC[4];
// THE WATER'S SHEEN (Josh, 2026-10-12: 'can this shiny effect, like a glossy sheen, be applied to water surfaces to reflect
// the lights?'): a broad soft highlight of the lamp and the lights round the sharp glints, as the wet stone has -- how strong
// (0 = none; the materials' F6 switches it), how tight; held under a soft limit so it never glares
uniform float uSheen, uSheenGloss;
// the materialize sweep (GpuRaster.StartMaterialize): the surface fades in as the texture front passes it (uMatz as the room's)
uniform vec4 uMatz;
out vec4 oColor;
" + NOISE_GLSL + @"
float soft(float t) { t = clamp(t, 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
" + WATER_GLSL + @"
void main() {
    float matR = uMatz.w > 0.5 ? smoothstep(-0.25 * uMatz.y, 1.4 * uMatz.y, uMatz.x - length(vView)) : 1.0;
    float fw = max(length(dFdx(vWorld)), length(dFdy(vWorld))) + 1e-6;
    // RIPPLES: three layers of moving noise, each half the size of the last and turned; a layer whose waves would be only
    // a few pixels across fades out
    vec2 sl = vec2(0.0); float sc = uRip.y, amp = uRip.x;
    mat2 R = mat2(0.80, 0.60, -0.60, 0.80), Rk = mat2(1.0);
    for (int o = 0; o < 3; o++) {
        float k = smoothstep(2.0, 6.0, sc / fw);
        vec4 n = noised(vec3(Rk * (vWorld.xz / sc), uTime * uRip.z * (1.0 + 0.35 * float(o)) + float(o) * 7.31));
        sl += transpose(Rk) * n.yz * (amp * k);
        Rk = R * Rk; sc *= 0.5; amp *= 0.75;
    }
    // DRIPS HITTING THE SURFACE (Josh, 2026-10-09, SPAROOM/2): each one a few crests running outward from where it fell,
    // fading as they spread -- only on water at the height it landed (a drip on the walkway rings nothing below)
    for (int i = 0; i < 16; i++) {
        if (i >= uDropN) break;
        if (abs(vWorld.y - uDrop[i].w) > 4.0) continue;
        vec2 dv = vWorld.xz - uDrop[i].xy; float d = length(dv) + 1e-3, age = uTime - uDrop[i].z;
        if (age < 0.0 || age > 2.8) continue;
        float r = age * 28.0, x = d - r;
        // a leading crest and a fainter one trailing it, as a real drop throws (measured: the first version, slope ~0.04 by
        // 1.5 s against the noise's 0.22, changed 9 sampled pixels in a view of six landings -- invisible)
        float env = (exp(-x * x / 45.0) + 0.55 * exp(-(x + 9.0) * (x + 9.0) / 45.0)) * exp(-age * 0.8) / (1.0 + r * 0.015);
        sl += (dv / d) * (cos(x * 0.75) * env * uDropK * 1.8);
    }
    vec3 N = normalize(vec3(-sl.x, 1.0, -sl.y));
    vec3 V = normalize(uEye - vWorld);
    float cv = max(dot(N, V), 0.0);
    float fres = uF0 + (1.0 - uF0) * pow(1.0 - cv, 5.0);
    float glow = glowAt(vWorld.xz);
    if (uPass == 0) {
        oColor = vec4(uGlowCol * (uDots * glow * (1.0 - 0.6 * fres)) * matR, 0.0);
        return;
    }
    // the reflection where the ripple bends it (pixels; less far off). Alpha 1 in the reflection = nothing reflected there
    vec3 nv = mat3(uView) * vec3(N.x, 0.0, N.z);
    vec2 sz = vec2(textureSize(uReflTex, 0));
    vec2 off = nv.xy * uDistort * clamp(180.0 / max(vView.z, 1.0), 0.2, 1.5);
    vec4 r0 = texture(uReflTex, gl_FragCoord.xy / sz), r1 = texture(uReflTex, (gl_FragCoord.xy + off) / sz);
    vec3 refl = mix(r1.rgb, r0.rgb, clamp(r1.a, 0.0, 1.0));
    // glints off the ripples: the flashlight (at the eye, so straight back) and the placed lights
    vec3 Nv = normalize(mat3(uView) * N), Vv = normalize(-vView), spec = vec3(0.0), sheen = vec3(0.0);
    float sg = max(uSheenGloss, 1.0), sk = (sg + 2.0) * 0.125;
    if (uLampOn != 0) {
        vec2 d = gl_FragCoord.xy - uLampC;
        float cs = inversesqrt(1.0 + min(dot(d, d) / (uFpx * uFpx), 2.0));
        float t = soft((cs - uCones.y) / (uCones.x - uCones.y)), h = soft((cs - uCones.w) / (uCones.z - uCones.w));
        float cone = uSpill + uHalo * h + max(0.0, 1.0 - uSpill - uHalo) * t;
        float dd = min(vView.z, 2046.0) / uLampRange;
        float hv = max(dot(Nv, Vv), 0.0);
        spec += vec3(1.0, 0.96, 0.88) * (uLampPower * cone / (1.0 + dd * dd) * (pow(hv, 90.0) * 1.6 + pow(hv, 16.0) * 0.1));
        if (uSheen > 0.0) sheen += vec3(1.0, 0.96, 0.88) * (uLampPower * cone / (1.0 + dd * dd) * pow(hv, sg) * sk);
    }
    for (int i = 0; i < 4; i++) {
        if (i >= uLightN) break;
        vec3 dl = uLightP[i].xyz - vView; float d2 = max(dot(dl, dl), 1.0);
        float hv = max(dot(Nv, normalize(dl * inversesqrt(d2) + Vv)), 0.0);
        // (Josh, SPAROOM/4 round 6: 'too intense ... soften it a bit and ... a slightly warm color': the colour squared keeps
        // a torch's orange from clipping to white; a faint broad sheen round the sharp glint)
        vec3 lc = uLightC[i] * uLightC[i];
        spec += lc * (uLightSpec * (pow(hv, 140.0) * 0.55 + pow(hv, 24.0) * 0.05) / (1.0 + d2 * uLightP[i].w));
        if (uSheen > 0.0) sheen += lc * (pow(hv, sg) * sk / (1.0 + d2 * uLightP[i].w));
    }
    spec *= uSpec;
    // the sheen, by the angle as a reflection is (more at a grazing look), softly held under 0.4
    sheen *= uSheen * (0.35 + 0.65 * fres);
    spec += 0.4 * (1.0 - exp(-sheen / 0.4));
    // the light from under the water, shimmering with the same web as the walls, less where the surface mirrors more
    float c = caustic(vWorld.xz, uTime, uCaus.y * 0.9, uCaus.z, fw);
    vec3 under = uGlowCol * (uGlow * glow * (0.6 + 0.9 * c) * (1.0 - 0.7 * fres));
    float sh = clamp(fres * uShine, 0.0, 0.85);
    oColor = vec4((refl * sh + spec + under) * matR, 1.0 - sh * matR);
}";
        // Depth only: the lamp's and the lights' views, and marking the water. Same position
        // arithmetic as the picture (invariant), so a surface lands at exactly its own depth.
        const string VS_DEPTH = @"#version 400 core
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec2 aUv;
layout(location = 4) in vec4 aRange; layout(location = 5) in float aFix;     // (texture repair: where a re-laid face's holes are)
uniform mat4 uView; uniform vec2 uF; uniform float uNear; uniform float uOffY;
out vec2 vUv; out vec3 vW; flat out vec4 vRange; flat out int vFix;
invariant gl_Position;
void main() {
    vec4 p = uView * vec4(aPos, 1.0);
    vUv = aUv; vW = aPos; vRange = aRange; vFix = int(aFix + 0.5);
    gl_Position = vec4(p.x * uF.x, -p.y * uF.y + uOffY * p.z, uNear, p.z);
}";
        const string FS_DEPTH = @"#version 400 core
in vec2 vUv; in vec3 vW; flat in vec4 vRange; flat in int vFix;
uniform sampler2D uMask; uniform float uFlip; uniform int uNoMask;
// a placed light's own view: a prop (its torch's sconce) this near the light casts nothing from it -- light pos, reach^2 (0 = off)
uniform vec4 uSkip;
void main() {
    if (uSkip.w > 0.0) { vec3 d = vW - uSkip.xyz; if (dot(d, d) < uSkip.w) discard; }
    if (uNoMask == 0) {
        vec2 uvF = vUv;
        if ((vFix & 1) != 0) { float t = mod((uvF.x - vRange.x) / vRange.z, 2.0); uvF.x = vRange.x + (t > 1.0 ? 2.0 - t : t) * vRange.z; }
        if ((vFix & 2) != 0) { float t = mod((uvF.y - vRange.y) / vRange.w, 2.0); uvF.y = vRange.y + (t > 1.0 ? 2.0 - t : t) * vRange.w; }
        vec2 st = vec2(uvF.x, uFlip > 0.5 ? 1.0 - uvF.y : uvF.y);
        if (texture(uMask, st).r < 0.5 / 255.0) discard;    // a hole stops no light
    }
}";
        // One triangle over the whole picture at depth 0 (infinitely far): wipes depth where the stencil says
        const string VS_CLEAR = @"#version 400 core
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}";
        const string FS_CLEAR = @"#version 400 core
void main() { }";
        // Dust: Motes.Draw's soft dot, a square of (2r+1) pixels round the mote's own pixel
        const string VS_MOTE = @"#version 400 core
layout(location = 0) in vec4 aM;        // screen x, y (pixels from the top left), depth, radius
layout(location = 1) in vec2 aK;        // beam strength (adds light), dark strength (mixes toward the dark colour)
uniform vec2 uWH; uniform float uNear;
out vec2 vC; out float vRad; out vec2 vK;
void main() {
    vec2 c = floor(aM.xy);
    float ir = ceil(aM.w);
    vC = c; vRad = aM.w; vK = aK;
    gl_PointSize = 2.0 * ir + 1.0;
    gl_Position = vec4((c + 0.5) / uWH * 2.0 - 1.0, uNear / aM.z, 1.0);
}";
        const string FS_MOTE = @"#version 400 core
in vec2 vC; in float vRad; in vec2 vK;
uniform vec3 uCol; uniform vec3 uDark;      // 0..255
out vec4 oColor;
void main() {
    vec2 o = floor(gl_FragCoord.xy) - vC;
    float d = length(o) / vRad;
    if (d > 1.0) discard;
    float fall = 1.0 - d * d, k = vK.x * fall, km = vK.y * fall;
    // with blending (1, 1 - alpha): picture * (1 - km) + dark * km + colour * k, as Motes.Draw
    oColor = vec4((uDark * km + uCol * k) / 255.0, km);
}";

        // ---- AFTER THE PICTURE (phase 3): what the overlay's own thread used to do --------------
        // Raster.PostCore's sharpen, integer for integer: green decides the push, held between the
        // darkest and brightest of the four neighbours; red and blue move with it. Edge rows and
        // columns, and pixels whose four neighbours all match, are left alone.
        const string FS_SHARP = @"#version 400 core
uniform sampler2D uPic; uniform int uK; uniform ivec2 uSize;
out vec4 oColor;
int px(ivec2 p) { ivec3 i = ivec3(round(texelFetch(uPic, p, 0).rgb * 255.0)); return (i.r << 16) | (i.g << 8) | i.b; }
vec4 col(int c) { return vec4(float((c >> 16) & 255), float((c >> 8) & 255), float(c & 255), 0.0) / 255.0; }
void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    int c = px(p);
    if (p.x == 0 || p.y == 0 || p.x == uSize.x - 1 || p.y == uSize.y - 1) { oColor = col(c); return; }
    int n = px(p + ivec2(0, -1)), s = px(p + ivec2(0, 1)), e = px(p + ivec2(1, 0)), w = px(p + ivec2(-1, 0));
    if (c == n && c == s && c == e && c == w) { oColor = col(c); return; }
    int cc = (c >> 8) & 255, cn = (n >> 8) & 255, cs = (s >> 8) & 255, ce = (e >> 8) & 255, cw = (w >> 8) & 255;
    int lo = min(min(min(cc, cn), min(cs, ce)), cw), hi = max(max(max(cc, cn), max(cs, ce)), cw);
    int v = cc + (((cc * 4 - cn - cs - ce - cw) * uK) >> 10);
    v = clamp(v, lo, hi);
    int d = v - cc;
    if (d == 0) { oColor = col(c); return; }
    int rr = clamp(((c >> 16) & 255) + d, 0, 255), bb = clamp((c & 255) + d, 0, 255);
    oColor = col((rr << 16) | (v << 8) | bb);
}";
        // Overlay.Present's compose: per picture pixel, the four game pixels round where it falls
        // (the column/row maps, the visor band's own column map), any of them that is the key
        // colour replaced by the picture, blended with 1/256 weights exactly as Overlay.Mix4.
        const string FS_COMP = @"#version 400 core
uniform sampler2D uPic; uniform sampler2D uScreen; uniform isampler2D uMap;
uniform float uHideFrom; uniform int uKey; uniform int uKey2; uniform ivec2 uBand; uniform int uVisor; uniform int uK; uniform ivec2 uSize;
uniform int uBlack;     // the game's book / item view: no world behind it, black wherever the 3D would show
uniform vec4 uHide;     // game viewport x0 y0 x1 y1: the game's drawings there are ignored (the host draws over them)
uniform vec4 uHide2;    // a second one (the scanner's wireframe box)
uniform sampler2D uMapLayer; uniform float uMapK, uMapDim;     // THE MAP (DrawMap): its layer, how far it is up, how dark the world goes behind it
uniform float uMapLines;     // the map's faint interlace (Josh, 2026-10-14: still meant to be seen in the visor): how dark its lines go
// THE VISOR'S LIGHTS on the map (Josh, 2026-10-14): two soft teal cones from the panel's top corners, fanned in at the map,
// as if they draw it -- while it pulses in, each SWEEPS (mirrored, the two alike): from the opposite top corner down across the
// view, then back up to rest, brighter and with a hot narrow core; then a faint glow that stays.
uniform vec4 uMlE;           // the two lights (picture px, rows from the top): left x, y, right x, y
uniform vec4 uMlD;           // (unused since the pulse took the cone's shape)
uniform vec4 uMlA;           // x: their reach (px: to the resting aim), y: unused, z: the cone's spread now (tan; the spotlight and the pulse alike), w: fan -> spotlight (0..1)
uniform vec4 uMlC;           // the spotlights' axes (unit vectors): left x, y, right x, y
uniform vec3 uMlK;           // x: unused, y: the pulse's strength (its fade and flicker in it), z: the spotlights' (their flicker in)
uniform vec3 uMlCol;         // their colour (0..1)
uniform vec2 uMlPulse;       // the pulse: its radius (px), 1 = running
uniform vec2 uMlFl;          // the spotlights' flicker, left and right (x their strength)
uniform float uMlConeR;      // how far out the spotlights reach yet (px): they spread out with the pulse
// THE CONE: one shape for the spotlight AND its pulse (Josh, 2026-10-14: 'the pulsing effect needs to adhere to those same
// shapes ... a wider version of those initial cones'): about its axis, gaussian across, the spread (tan) set from outside --
// wide while the pulse runs, the resting width after.
float coneAcross(vec2 d, vec2 ax, float D, float spread) {
    float along = dot(d, ax), across = dot(d, vec2(-ax.y, ax.x));
    if (along <= 0.0) return 0.0;
    float c = across / (along * spread + D * 0.025); return exp(-c * c * 1.7);
}
// THE PULSE ('that pulse with the sort of ribbing light effect is the only one I want to see ... extend indefinitely and off
// screen'): as the echo scan's shell, a band running out from the light, ribs of light trailing it, in the CONE's shape; no
// fall-off with distance -- it runs on past the screen's edges.
float beamPulse(vec2 q, vec2 e, vec2 ax, float D, float spread, float R) {
    vec2 d = q - e; float r = length(d);
    float band = exp(-pow((r - R) / (D * 0.0175), 2.0)) * 0.48;        // (the lead band: Josh, 2026-10-14, 'a bit less bright', then half as thick and 20% fainter)
    float behind = R - r, rings = 0.0;
    if (behind > 0.0) { float c = 0.5 + 0.5 * cos(behind / (D * 0.07) * 6.2831853); rings = 0.45 * c * c * c * c * exp(-behind / (D * 0.3)); }
    return (band + rings) * coneAcross(d, ax, D, spread) * smoothstep(0.0, D * 0.05, r);
}
// THE SPOTLIGHT (Josh, 2026-10-14: 'when they come to rest, have them fade into the previous spotlight versions'): the cone,
// fading away from the light, a small glow where it leaves the panel; out only as far as R (the pulse carries it out).
float beamCone(vec2 q, vec2 e, vec2 ax, float D, float spread, float R) {
    vec2 d = q - e; float along = dot(d, ax);
    float g = exp(-dot(d, d) / (D * D * 0.0016)) * 0.55;
    if (along > 0.0) {
        float fall = exp(-along / (D * 0.95)) * smoothstep(0.0, D * 0.05, along) * (1.0 - smoothstep(D * 0.9, D * 1.6, along));
        g += coneAcross(d, ax, D, spread) * fall * (1.0 - smoothstep(R - D * 0.2, R, length(d)));
    }
    return g;
}
// ---- the room's depth, the camera, and what is drawn into the air ----
uniform sampler2D uDepth; uniform float uNear, uFpx; uniform vec2 uCentre; uniform mat4 uCamWorld;
uniform float uAO, uAORad; uniform vec3 uKernel[12];
uniform int uMistOn; uniform vec4 uMist; uniform vec3 uMistCol; uniform vec3 uMistNoise; uniform float uTime;
uniform float uBeam, uHaze, uMistScatter; uniform vec3 uBeamCol; uniform vec2 uBeamCone; uniform vec3 uBeamOrg; uniform float uBeamMax, uBeamFall;
uniform float uMarchMax; uniform int uSteps;
uniform int uLampOn; uniform float uLampPower, uLampRange, uSpill, uHalo; uniform vec4 uCones; uniform vec2 uLampC;
uniform int uLampMaps; uniform sampler2D uLampMap[2]; uniform vec2 uLampOff[2]; uniform vec3 uLampMapF; uniform ivec2 uLampMapSize; uniform float uSBias;
// ---- VOLUMETRIC FOG (2026-10-08, the first room): the air absorbs (black fog, up to uVol.y opaque), and the placed
// lights and the flashlight scatter in it -- each light's all-round shadow map says which air it reaches (shafts)
uniform int uVolOn; uniform vec4 uVol;      // density per unit, max opacity, scatter (share of the density), flashlight's share
uniform vec4 uVol2;                         // anisotropy (forward scattering), a light's reach in the air, how far to march, steps
uniform vec3 uVolCol;                       // the fog's own colour, 0..255 (black)
uniform float uVolCut;                      // the flashlight CUTS THROUGH: inside its cone the fog thins by up to this share
// ...and so do the PLACED LIGHTS (Josh, 2026-10-09: the torch and the shaft 'should dispose of the fog just like my flashlight'):
// a surface they light comes through the fog by up to uVolLit more (its share, from the picture's alpha), and the air they light
// glows through the darkness between it and the eye by up to uVolLitAir
uniform float uVolLit, uVolLitAir;
uniform int uVN; uniform vec4 uVLP[4]; uniform vec3 uVLC[4]; uniform vec3 uVLF[4]; uniform sampler2D uVLMap[4]; uniform mat3 uVCubeAx[6];
// THE LIGHTS' AIR ONLY INSIDE THE ROOM (2026-10-14, BAPTIST/1: the sun outside its windows lit the open sky above the walls):
// a world box (the room's own bounds); air outside it takes no placed light. uAirBox 0 = everywhere
uniform int uAirBox; uniform vec3 uAirLo, uAirHi;
// each air light's GATE (see FS_MAIN's uGateLo): .w of lo = on; uVLW its place (world)
uniform vec4 uVGLo[4]; uniform vec3 uVGHi[4]; uniform vec3 uVLW[4];
bool segThrough(vec3 a, vec3 b, vec3 lo, vec3 hi) {
    vec3 d = b - a, inv = 1.0 / mix(d, vec3(1e-9), lessThan(abs(d), vec3(1e-9)));
    vec3 t0 = (lo - a) * inv, t1 = (hi - a) * inv, tn = min(t0, t1), tf = max(t0, t1);
    float n = max(max(max(tn.x, tn.y), tn.z), 0.0), f = min(min(min(tf.x, tf.y), tf.z), 1.0);
    return n <= f;
}
// per light, in the air: its cross axes and direction (view space), cone (cos inner, cos outer; outer < -1.5 = all round),
// its strength in the air, its RAYS (0..1: streaks across the cone, drifting), and its own reach (0 = the volume's)
uniform mat3 uVLB[4]; uniform vec4 uVLK[4]; uniform float uVLR[4]; uniform vec3 uVLM[4]; uniform vec2 uVLT[4];
uniform int uPass; uniform sampler2D uVolTex; uniform ivec2 uVolSize;     // the fog at half size (VolHalf): 1 = making it, 2 = reading it
// THE PAINTED DARKNESS (GpuRaster.BuildPaintField): a floor plan of how dark the art is painted, x0 z0 1/width 1/depth;
// extra black density per unit where it is fully dark, and how opaque it may get
uniform int uPaintOn; uniform sampler2D uPaintTex; uniform vec4 uPaintBox; uniform vec2 uPaint;
uniform vec3 uPaintCol;                     // its colour, 0..255 (black) -- apart from the fog's own (Josh, MINEHEAD/3: beige air, dark corners)
out vec4 oColor;
int px(sampler2D t, ivec2 p) { ivec3 i = ivec3(round(texelFetch(t, p, 0).rgb * 255.0)); return (i.r << 16) | (i.g << 8) | i.b; }
ivec3 ch(int v) { return ivec3((v >> 16) & 255, (v >> 8) & 255, v & 255); }
float soft(float t) { t = clamp(t, 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
// FS_SHARP's arithmetic for this one pixel (the compose needs the sharpened picture nowhere else)
int sharpened(ivec2 p) {
    int c = px(uPic, p);
    if (uK <= 0 || p.x == 0 || p.y == 0 || p.x == uSize.x - 1 || p.y == uSize.y - 1) return c;
    int n = px(uPic, p + ivec2(0, -1)), s = px(uPic, p + ivec2(0, 1)), e = px(uPic, p + ivec2(1, 0)), w = px(uPic, p + ivec2(-1, 0));
    if (c == n && c == s && c == e && c == w) return c;
    int cc = (c >> 8) & 255, cn = (n >> 8) & 255, cs = (s >> 8) & 255, ce = (e >> 8) & 255, cw = (w >> 8) & 255;
    int lo = min(min(min(cc, cn), min(cs, ce)), cw), hi = max(max(max(cc, cn), max(cs, ce)), cw);
    int v = clamp(cc + (((cc * 4 - cn - cs - ce - cw) * uK) >> 10), lo, hi);
    int d = v - cc;
    if (d == 0) return c;
    return (clamp(((c >> 16) & 255) + d, 0, 255) << 16) | (v << 8) | clamp((c & 255) + d, 0, 255);
}
// a pixel's place in view space (x right, y up, z ahead), from its depth; z < 0 = nothing there
vec3 viewAt(ivec2 q) {
    q = clamp(q, ivec2(0), uSize - 1);
    float d = texelFetch(uDepth, q, 0).r; if (d <= 0.0) return vec3(0.0, 0.0, -1.0);
    float w = uNear / d; vec2 fc = vec2(q) + 0.5;
    return vec3((fc.x - uCentre.x) / uFpx * w, (uCentre.y - fc.y) / uFpx * w, w);
}
// CORNERS AND CONTACT: how much of the hemisphere over this point is inside other geometry
float ambientOcc(ivec2 p, vec3 Vp) {
    vec3 r = viewAt(p + ivec2(1, 0)), l = viewAt(p - ivec2(1, 0)), u = viewAt(p + ivec2(0, 1)), d = viewAt(p - ivec2(0, 1));
    vec3 dx = (r.z > 0.0 && (l.z < 0.0 || abs(r.z - Vp.z) < abs(Vp.z - l.z))) ? r - Vp : Vp - l;
    vec3 dy = (u.z > 0.0 && (d.z < 0.0 || abs(u.z - Vp.z) < abs(Vp.z - d.z))) ? u - Vp : Vp - d;
    vec3 n = cross(dx, dy); float nl = length(n); if (nl < 1e-6) return 1.0;
    n /= nl; if (dot(n, -Vp) < 0.0) n = -n;
    float a = 6.2832 * ign(vec2(p));
    vec3 t0 = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
    vec3 tg = t0 * cos(a) + cross(n, t0) * sin(a), bt = cross(n, tg);
    float occ = 0.0;
    for (int k = 0; k < 12; k++) {
        vec3 S = Vp + (tg * uKernel[k].x + bt * uKernel[k].y + n * uKernel[k].z) * uAORad;
        if (S.z < 1.0) continue;
        vec2 sp = uCentre + vec2(S.x, -S.y) * uFpx / S.z;
        ivec2 sq = ivec2(sp);
        if (sq.x < 0 || sq.y < 0 || sq.x >= uSize.x || sq.y >= uSize.y) continue;
        float sd = texelFetch(uDepth, sq, 0).r; if (sd <= 0.0) continue;
        float sz = uNear / sd;
        if (sz < S.z - 0.8) occ += soft(uAORad / abs(Vp.z - sz));
    }
    float ao = 1.0 - uAO * occ / 12.0;
    return mix(ao, 1.0, soft((Vp.z - 350.0) / 450.0));
}
// value noise and a little fbm, for the mist's wisps
float hash(vec3 q) { q = fract(q * 0.3183099 + vec3(0.1, 0.2, 0.3)); q *= 17.0; return fract(q.x * q.y * q.z * (q.x + q.y + q.z)); }
float vnoise(vec3 x) {
    vec3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm(vec3 x) { return 0.62 * vnoise(x) + 0.38 * vnoise(x * 2.07 + vec3(5.2, 1.3, 7.7)); }
// the helmet lamp at a point in the air: cone by where it is on the screen (as the surfaces), falloff, its shadow
// The BEAM is a faint FAN rising from under the visor (uBeamOrg, view space: below the eye) to
// where the lamp points, in its own cone (Josh, 2026-10-06: the lamp's whole spread lit in the air
// filled the view; a narrow shaft from the side was not liked either). Seen from exactly the eye
// a beam is only a glow round the centre; from below it, it fans up into the view.
// Henyey-Greenstein, relative to scattering the same every way (1 = isotropic): bright looking toward a light
float hgRel(float c, float g) { float d = 1.0 + g * g - 2.0 * g * c; return (1.0 - g * g) / (d * sqrt(d)); }
// does the air at q (from light k to the point, view space) see the light? its all-round map, one texel
float airLit(int k, vec3 q) {
    int fb = 0; float lz = dot(q, uVCubeAx[0][2]);
    for (int f = 1; f < 6; f++) { float z = dot(q, uVCubeAx[f][2]); if (z > lz) { lz = z; fb = f; } }
    if (lz < 0.5) return 1.0;
    float lf = uVLF[k].x, fsz = uVLF[k].y, hs = fsz * 0.5;
    vec2 s = clamp(vec2(dot(q, uVCubeAx[fb][0]) / lz * lf + hs, hs - dot(q, uVCubeAx[fb][1]) / lz * lf), vec2(1.0), vec2(fsz - 2.0));
    float d = texelFetch(uVLMap[k], ivec2(fb % 3, fb / 3) * int(fsz) + ivec2(s), 0).r;
    return d > 1.03 * uNear / lz ? 0.0 : 1.0;
}
float lampAir(vec3 P, vec3 axis) {
    vec3 v = P - uBeamOrg; float vl = length(v);
    float cs = dot(v, axis) / max(vl, 1e-3);
    float cone = soft((cs - uBeamCone.y) / (uBeamCone.x - uBeamCone.y));
    // brightest near the lamp, fading with distance from it (uBeamFall: half as bright that far
    // away), so the fan reads rising from under the visor rather than as a disc at the far end
    float dd = vl / uBeamFall;
    // (no shadow test: the shaft starts a few units from the eye, so whatever is between it and
    // the surfaces in view is hardly ever in its way -- and the lamp maps' test, made for surfaces,
    // put all the air past ~20 units in shadow and cut the shaft off short)
    return uLampPower * cone / (1.0 + dd * dd);
}
// THE FOG'S MARCH (its light scattered toward the eye along this line of sight, L long; dens: the air here; j: the
// pixel's stagger). Run for every pixel, or (VolHalf, 2026-10-08) for every second pixel each way into a half-size
// picture the compose then reads back depth-aware -- a quarter of the work: it was ~40% of a 5.5 M frame.
vec3 volMarch(vec3 dir, float L, float dens, float j, out float tau) {
    float floorT = 1.0 - uVol.y; tau = 0.0;
    float cutK = dens / max(uVol.x, 1e-9);           // (the flashlight thins the painted darkness as it thins the fog)
    vec3 axis = normalize(normalize(vec3((uLampC.x - uCentre.x) / uFpx, (uCentre.y - uLampC.y) / uFpx, 1.0)) * 400.0 - uBeamOrg);
    int n = int(uVol2.w); float Lm = min(L, uVol2.z), stepL = Lm / float(n);
    vec3 ins = vec3(0.0);
    for (int i = 0; i < 64; i++) {
        if (i >= n) break;
        float t = (float(i) + j) * stepL; vec3 P = dir * t;
        if (uPaintOn != 0) {
            vec3 Pw = (uCamWorld * vec4(P, 1.0)).xyz;
            tau += texture(uPaintTex, (Pw.xz - uPaintBox.xy) * uPaintBox.zw).r * uPaint.x * cutK * stepL;
        }
        float Tt = max(exp(-dens * t), floorT) * max(exp(-tau), 1.0 - uPaint.y);
        vec3 li = vec3(0.0), lb = vec3(0.0);
        int vn = uVN; vec3 Pb = vec3(0.0); bool haveW = false;
        if (uAirBox != 0) { Pb = (uCamWorld * vec4(P, 1.0)).xyz; haveW = true; if (any(lessThan(Pb, uAirLo)) || any(greaterThan(Pb, uAirHi))) vn = 0; }
        for (int k = 0; k < 4; k++) {
            if (k >= vn) break;
            if (uVGLo[k].w > 0.5) { if (!haveW) { Pb = (uCamWorld * vec4(P, 1.0)).xyz; haveW = true; } if (!segThrough(uVLW[k], Pb, uVGLo[k].xyz, uVGHi[k])) continue; }
            vec3 dl = uVLP[k].xyz - P; float d2 = max(dot(dl, dl), 1e-4), d = sqrt(d2);
            float rk = uVLR[k] > 0.0 ? uVLR[k] : uVol2.y;
            float att = uVLK[k].z / (1.0 + d2 / (rk * rk));
            if (uVLK[k].y > -1.5) {
                // a spot: only inside its cone; and its RAYS -- a pattern across the cone, constant along each line from
                // the light, so it reads as shafts spilling from the source (drifting slowly)
                vec3 q = -dl; float along = dot(q, uVLB[k][2]);
                if (along <= 0.0) continue;
                float cs = along / d;
                att *= soft((cs - uVLK[k].y) / max(uVLK[k].x - uVLK[k].y, 1e-3));
                if (uVLK[k].w > 0.0 && att > 0.0) {
                    vec2 uv = vec2(dot(q, uVLB[k][0]), dot(q, uVLB[k][1])) / along;
                    float nz = fbm(vec3(uv * 9.0, uTime * 0.04 + float(k) * 3.1));
                    att *= mix(1.0, smoothstep(0.38, 0.78, nz) * 1.8, uVLK[k].w);
                }
            }
            float vis = uVLF[k].z > 0.5 ? airLit(k, -dl) : 1.0;
            li += uVLC[k] * mix(vec3(1.0), uVLM[k], smoothstep(uVLT[k].x, uVLT[k].y, d)) * (att * hgRel(dot(dl / d, dir), uVol2.x) * vis);
        }
        if (uLampOn != 0 && uVol.w > 0.0) lb = (uBeamCol / 255.0) * (lampAir(P, axis) * uVol.w);
        ins += (mix(Tt, 1.0, uVolLitAir) * li + Tt * lb) * stepL;
    }
    return ins;
}
// how dense the air is at this pixel (fc: full-size pixel centre): thinner where the flashlight points, as much as it is on
float volDens(vec2 fc) {
    float dens = uVol.x;
    if (uVolCut > 0.0 && uLampOn != 0) {
        vec2 dc = fc - uLampC; float cs = inversesqrt(1.0 + min(dot(dc, dc) / (uFpx * uFpx), 2.0));
        dens *= 1.0 - uVolCut * soft((cs - uCones.w) / (uCones.z - uCones.w)) * clamp(uLampPower / 1.5, 0.0, 1.0);
    }
    return dens;
}
// the half-size march, back at full size: the four nearest results, bilinear, each counted by how near its depth is to
// this pixel's (so a bright shaft never bleeds onto a pillar in front of it); none near enough: the nearest in depth
// the line of sight's length at the full-size pixel q (as main works it out)
float sightLen(ivec2 q) {
    q = clamp(q, ivec2(0), uSize - 1);
    float d = texelFetch(uDepth, q, 0).r; vec2 fq = vec2(q) + 0.5;
    vec3 rq = vec3((fq.x - uCentre.x) / uFpx, (uCentre.y - fq.y) / uFpx, 1.0);
    return d > 0.0 ? length(rq * (uNear / d)) : uVol2.z;
}
vec4 volUp(ivec2 p, float L) {
    vec2 f = (vec2(p) + 0.5) * 0.5 - 0.5; ivec2 i0 = ivec2(floor(f)); vec2 w = f - floor(f);
    vec4 acc = vec4(0.0), best = vec4(0.0); float ws = 0.0, bd = 1e9;
    for (int k = 0; k < 4; k++) {
        ivec2 o = ivec2(k & 1, k >> 1), q = clamp(i0 + o, ivec2(0), uVolSize - 1);
        vec4 s = texelFetch(uVolTex, q, 0);
        float dd = abs(sightLen(q * 2) - L) / max(L, 1.0);
        float wk = (o.x == 1 ? w.x : 1.0 - w.x) * (o.y == 1 ? w.y : 1.0 - w.y) * exp(-dd * dd * 400.0);
        acc += s * wk; ws += wk;
        if (dd < bd) { bd = dd; best = s; }
    }
    return ws > 1e-4 ? acc / ws : best;
}void main() {
    // the half-size pass of the fog's march (uPass 1): this pixel stands for the full-size one at twice its place
    if (uPass == 1) {
        ivec2 q = min(ivec2(gl_FragCoord.xy) * 2, uSize - 1);
        float dq = texelFetch(uDepth, q, 0).r; vec2 fq = vec2(q) + 0.5;
        vec3 rq = vec3((fq.x - uCentre.x) / uFpx, (uCentre.y - fq.y) / uFpx, 1.0);
        float Lq = dq > 0.0 ? length(rq * (uNear / dq)) : uVol2.z;
        float tq; vec3 iq = volMarch(normalize(rq), Lq, volDens(fq), ign(vec2(q) + vec2(91.0, 7.0)), tq);
        oColor = vec4(iq, tq);
        return;
    }
    ivec2 p = ivec2(gl_FragCoord.xy);
    int pic = sharpened(p);
    if (uAO > 0.0 || uMistOn != 0 || (uBeam > 0.0 && uLampOn != 0) || uVolOn != 0) {
        vec3 col = vec3(ch(pic));
        float dz = texelFetch(uDepth, p, 0).r;
        vec2 fc = vec2(p) + 0.5;
        vec3 ray = vec3((fc.x - uCentre.x) / uFpx, (uCentre.y - fc.y) / uFpx, 1.0);
        vec3 Vp = dz > 0.0 ? ray * (uNear / dz) : ray * uMarchMax;
        if (dz > 0.0 && uAO > 0.0 && Vp.z < 800.0) col *= ambientOcc(p, Vp);     // (from 800 on its fade makes it exactly 1: 16 depth reads saved there)
        if (uMistOn != 0 || (uBeam > 0.0 && uLampOn != 0)) {
            // THE AIR between the eye and this pixel.
            vec3 dir = normalize(ray);
            float L = min(dz > 0.0 ? length(Vp) : 220.0, uMarchMax);          // (the void past the room: only a little way in)
            vec3 eyeW = uCamWorld[3].xyz, endW = (uCamWorld * vec4(dir * L, 1.0)).xyz;
            // MIST: fog that thins with height above the floor has an exact thickness along a straight
            // line -- no marching. Its wisps come from noise at two points on the line, drifting.
            float T = 1.0, wisp = 1.0, ia = 1.0 / uMist.y;
            float h0 = max(eyeW.y - uMist.z, -0.5 * uMist.y), h1 = max(endW.y - uMist.z, -0.5 * uMist.y);
            if (uMistOn != 0) {
                float e0 = exp(-h0 * ia), e1 = exp(-h1 * ia);
                float tau = abs(h1 - h0) < 1e-3 ? uMist.x * L * e0 : uMist.x * L * (e0 - e1) / ((h1 - h0) * ia);
                tau = min(tau, uMist.w * L);
                if (tau > 0.002) {
                    vec3 drift = vec3(uTime * uMistNoise.y, uTime * uMistNoise.y * 0.15, uTime * uMistNoise.y * 0.6);
                    float n = 0.6 * fbm(endW * uMistNoise.x + drift) + 0.4 * fbm(mix(eyeW, endW, 0.6) * uMistNoise.x + drift);
                    wisp = mix(1.0, clamp(n * 2.2 - 0.35, 0.0, 2.0), uMistNoise.z);
                    T = exp(-tau * wisp);
                }
            }
            // THE BEAM: lit air along the same line, in slices (staggered per pixel), the mist catching it
            float scat = 0.0;
            if (uBeam > 0.0 && uLampOn != 0) {
                // where the lamp points (its own lag included), from its place beside the eye
                vec3 aim = normalize(vec3((uLampC.x - uCentre.x) / uFpx, (uCentre.y - uLampC.y) / uFpx, 1.0)) * 400.0;
                vec3 axis = normalize(aim - uBeamOrg);
                // the stretch of this line of sight inside the shaft's outer cone, exactly (a ray and
                // a cone: a quadratic), so the slices go only where the shaft is and none miss it
                float c2 = uBeamCone.y * uBeamCone.y, da = dot(dir, axis);
                vec3 w = -uBeamOrg; float wa = dot(w, axis);
                float qa = da * da - c2, qb = 2.0 * (da * wa - c2 * dot(dir, w)), qc = wa * wa - c2 * dot(w, w);
                float ta = 1e9, tb = -1e9, disc = qb * qb - 4.0 * qa * qc;
                if (abs(qa) < 1e-6) { if (abs(qb) > 1e-6) { float r = -qc / qb; if (qb > 0.0) { ta = r; tb = 1e9; } else { ta = -1e9; tb = r; } } }
                else if (disc >= 0.0) {
                    float sq = sqrt(disc), r1 = (-qb - sq) / (2.0 * qa), r2 = (-qb + sq) / (2.0 * qa);
                    float rlo = min(r1, r2), rhi = max(r1, r2);
                    if (qa < 0.0) { ta = rlo; tb = rhi; }                                   // a line across the cone: inside between
                    else if (da > 0.0) { ta = rhi; tb = 1e9; }                             // a line along it: inside past the far root
                    else { ta = -1e9; tb = rlo; }
                }
                else if (qa > 0.0) { ta = -1e9; tb = 1e9; }                                // along it and never leaving
                // (only the forward half of the double cone: past the lamp, not behind it)
                if (abs(da) < 1e-6) { if (wa <= 0.0) tb = -1e9; }
                else if (da > 0.0) ta = max(ta, -wa / da);
                else tb = min(tb, -wa / da);
                ta = max(ta, 1.0); tb = min(tb, L);
                float stepL = max(tb - ta, 0.0) / float(uSteps), j = ign(vec2(p) + vec2(17.0, 43.0)), Tb = 1.0;
                for (int i = 0; i < uSteps && stepL > 0.0; i++) {
                    float t = ta + (float(i) + j) * stepL;
                    float li = lampAir(dir * t, axis);
                    float dm = 0.0;
                    if (uMistOn != 0) {
                        float hh = max(mix(h0, h1, t / max(L, 1e-3)), -0.5 * uMist.y);
                        dm = min(uMist.x * exp(-hh * ia), uMist.w) * wisp;
                        Tb *= exp(-dm * stepL);
                    }
                    if (li > 0.0) scat += Tb * (uHaze + dm * uMistScatter) * li * stepL;
                }
            }
            // the beam saturates gently: never more than uBeamMax of white on top of what is there
            // (kept faint: lit air adds a veil, and the beam is there to help see, not to hide)
            col = col * T + uMistCol * (1.0 - T) + uBeamCol * uBeamMax * (1.0 - exp(-scat * uBeam * 2.2));
        }
        if (uVolOn != 0) {
            // THE FOG: what reaches the eye from the surface (or the void) through it, and what the lights add on the way.
            // Marched in uVol2.w jittered steps up to uVol2.z units; each step asks every light whether it sees that air.
            vec3 dir = normalize(ray);
            float L = dz > 0.0 ? length(Vp) : uVol2.z, floorT = 1.0 - uVol.y;
            // where the flashlight points (its wide halo cone), the fog is thinner -- as much as the lamp is on
            float dens = volDens(gl_FragCoord.xy);

            float T = max(exp(-dens * L), floorT);
            vec3 ins; float tauP;
            if (uPass == 2) { vec4 vu = volUp(p, L); ins = vu.rgb; tauP = vu.a; }
            else ins = volMarch(dir, L, dens, ign(vec2(p) + vec2(91.0, 7.0)), tauP);
            float oF = 1.0 - T, Tp = max(exp(-tauP), 1.0 - uPaint.y), oP = 1.0 - Tp;
            T *= Tp;                                       // the painted darkness on top of the fog
            T = mix(T, 1.0, uVolLit * texelFetch(uPic, p, 0).a);     // lit by a placed light (or a flame): through the dark
            // (what is hidden goes to the fog's colour and the painted darkness's, each as much as it hides)
            vec3 fogC = oF + oP > 1e-4 ? (uVolCol * oF + uPaintCol * oP) / (oF + oP) : uVolCol;
            col = col * T + fogC * (1.0 - T) + ins * (uVol.x * uVol.z * 255.0);
        }
        ivec3 ic = ivec3(clamp(round(col), 0.0, 255.0));
        pic = (ic.r << 16) | (ic.g << 8) | ic.b;
    }
    if (uBlack != 0) pic = 0;
    if (uMapK > 0.001) {
        // the world behind the map: faded back (darker, a little greyer) but still there; the map laid over it
        vec3 c0 = vec3(ch(pic)); float l0 = dot(c0, vec3(0.30, 0.59, 0.11));
        c0 = mix(c0, mix(c0, vec3(l0), 0.35) * (1.0 - uMapDim), uMapK);
        vec4 m = texelFetch(uMapLayer, p, 0);
        c0 = c0 * (1.0 - min(1.0, m.a) * uMapK) + m.rgb * 255.0 * uMapK;
        // THE VISOR'S LIGHTS: screened over the map view, a touch of grain so the faint gradients do not band
        if (uMlK.x + uMlK.y + uMlK.z > 0.0) {
            vec2 q = vec2(p) + 0.5;
            float m = uMlA.w, g = 0.0;
            if (uMlPulse.y > 0.0) g += (beamPulse(q, uMlE.xy, uMlC.xy, uMlA.x, uMlA.z, uMlPulse.x) + beamPulse(q, uMlE.zw, uMlC.zw, uMlA.x, uMlA.z, uMlPulse.x)) * uMlK.y;
            if (m > 0.0) g += (beamCone(q, uMlE.xy, uMlC.xy, uMlA.x, uMlA.z, uMlConeR) * uMlFl.x + beamCone(q, uMlE.zw, uMlC.zw, uMlA.x, uMlA.z, uMlConeR) * uMlFl.y) * uMlK.z * m;
            g *= uMapK;
            g += (fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.006 * min(1.0, g * 20.0);
            vec3 li = clamp(uMlCol * g, 0.0, 1.0);
            c0 = 255.0 - (255.0 - c0) * (1.0 - li);
        }
        // THE VISOR'S INTERLACE over the whole map view: every few rows (one in max(2, rows / 500)) a little darker
        if (uMapLines > 0.0) { int lp = max(2, int(round(float(uSize.y) / 500.0))); if (p.y % lp == 0) c0 *= 1.0 - uMapLines * uMapK; }
        ivec3 mc = ivec3(clamp(round(c0), 0.0, 255.0)); pic = (mc.r << 16) | (mc.g << 8) | mc.b;
    }
    vec4 picC = vec4(vec3(ch(pic)) / 255.0, 0.0);
    bool band = uVisor != 0 && (p.y < uBand.x || p.y >= uBand.y);
    int ix = texelFetch(uMap, ivec2(p.x, band ? 2 : 0), 0).r;
    if (ix < 0) { oColor = picC; return; }                  // beyond the game's own picture
    int wx = texelFetch(uMap, ivec2(p.x, band ? 3 : 1), 0).r;
    int iy = texelFetch(uMap, ivec2(p.y, 4), 0).r, wy = texelFetch(uMap, ivec2(p.y, 5), 0).r;
    if (iy < 0) { oColor = picC; return; }                  // below the game's view (under the panel)
    // (ix + 1, iy + 1): this pixel blends the game's pixel below and to the right too -- testing only
    // (ix, iy) let the box's top row and left column bleed half into the row and column outside it)
    if (float(iy + 1) >= uHideFrom) { oColor = picC; return; }    // the panel's own rows: the host draws them
    if (uHide.z > uHide.x && float(ix + 1) >= uHide.x && float(ix) < uHide.z && float(iy + 1) >= uHide.y && float(iy) < uHide.w) { oColor = picC; return; }
    if (uHide2.z > uHide2.x && float(ix + 1) >= uHide2.x && float(ix) < uHide2.z && float(iy + 1) >= uHide2.y && float(iy) < uHide2.w) { oColor = picC; return; }
    int a = px(uScreen, ivec2(ix, iy)), b = px(uScreen, ivec2(ix + 1, iy)), c = px(uScreen, ivec2(ix, iy + 1)), d = px(uScreen, ivec2(ix + 1, iy + 1));
    // (the key: the colour measured as the commonest in the view, AND the key the host hands the game -- uKey2; KeyAlso)
    bool ka = a == uKey || a == uKey2, kb = b == uKey || b == uKey2, kc = c == uKey || c == uKey2, kd = d == uKey || d == uKey2;
    if (ka && kb && kc && kd) { oColor = picC; return; }
    if (ka) a = pic; if (kb) b = pic; if (kc) c = pic; if (kd) d = pic;
    int nx = 256 - wx, ny = 256 - wy;
    ivec3 top = (ch(a) * nx + ch(b) * wx) >> 8, bot = (ch(c) * nx + ch(d) * wx) >> 8;
    ivec3 r = (top * ny + bot * wy) >> 8;
    oColor = vec4(vec3(r) / 255.0, 0.0);
}";
        // PARTICLES (Particles.Gather): soft round sprites in the room's depth -- premultiplied, so
        // the alpha ones blend over and the glowing ones (embers) add. Steam is given a billowy
        // edge, a drip is drawn as a narrow streak.
        const string VS_PART = @"#version 400 core
layout(location = 0) in vec4 aP;        // world x y z, radius (world units)
layout(location = 1) in vec4 aC;        // r g b (0..255), alpha
layout(location = 2) in vec2 aM;        // additive, seed (1+ = steam, -1 = drip)
uniform mat4 uView; uniform vec2 uF; uniform float uNear, uFpx, uOffY;
out vec4 vC; out float vSeed;
void main() {
    vec4 p = uView * vec4(aP.xyz, 1.0);
    gl_Position = vec4(p.x * uF.x, -p.y * uF.y + uOffY * p.z, uNear, p.z);
    float ps = clamp(2.0 * aP.w * uFpx / max(p.z, 1.0), 1.5, 256.0);
    if (aM.y < -1.5) ps = 1.0 + fract(-aM.y) * 1.2;      // a SPARK (seed -2..-3): 1 to 2 pixels, however near or far (Josh, 2026-10-14)
    gl_PointSize = ps;
    vC = aC; vSeed = aM.y;
}";
        const string FS_PART = @"#version 400 core
in vec4 vC; in float vSeed;
out vec4 oColor;
float hash(vec3 q) { q = fract(q * 0.3183099 + vec3(0.1, 0.2, 0.3)); q *= 17.0; return fract(q.x * q.y * q.z * (q.x + q.y + q.z)); }
float vnoise(vec3 x) {
    vec3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x), mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
               mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x), mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
void main() {
    vec2 q = gl_PointCoord * 2.0 - 1.0;
    if (vSeed >= 3.0) {
        // FINE STEAM (Josh, SPAROOM round 7: 'too large ... tighten ... more modern/high resolution'): small wisps whose
        // shape is three layers of noise, cut with a firm threshold, so each reads as a curl of vapour, not a soft ball
        float s = vSeed - 3.0, d2f = dot(q, q);
        if (d2f > 1.0) discard;
        float n = 0.5 * vnoise(vec3(q * 2.6 + s * 13.0, s * 7.0)) + 0.3 * vnoise(vec3(q * 6.0 + s * 5.0, 2.0 + s)) + 0.2 * vnoise(vec3(q * 13.0 + s * 3.0, 4.0));
        float af = vC.a * pow(1.0 - d2f, 1.5) * smoothstep(0.42, 0.72, n);
        oColor = vec4(vC.rgb / 255.0 * af, af);
        return;
    }
    if (vSeed < -1.5) { oColor = vec4(vC.rgb / 255.0 * vC.a, vC.a); return; }      // a spark: a hard point, no soft edge
    if (vSeed < -0.5) q.x *= 3.0;                         // a drip: a narrow streak
    float d2 = dot(q, q); if (d2 > 1.0) discard;
    float a = vC.a * (1.0 - d2) * (1.0 - d2);
    if (vSeed >= 1.0) a *= clamp((0.6 * vnoise(vec3(q * 2.5 + vSeed * 13.0, vSeed * 7.0)) + 0.4 * vnoise(vec3(q * 5.0 + vSeed * 3.0, 1.0))) * 1.7 - 0.25, 0.0, 1.0);
    oColor = vec4(vC.rgb / 255.0 * a, a);
}";
        uint Compile(uint type, string src, string what)
        {
            uint sh = glCreateShader(type);
            glShaderSource(sh, 1, new[] { src }, null);
            glCompileShader(sh);
            int ok; glGetShaderiv(sh, GL_COMPILE_STATUS, out ok);
            if (ok == 0) { var sb = new StringBuilder(8192); int n; glGetShaderInfoLog(sh, sb.Capacity, out n, sb); throw new InvalidOperationException("shader for " + what + " did not compile: " + sb); }
            return sh;
        }
        uint Link(string vsSrc, string fsSrc, string what)
        {
            uint vs = Compile(GL_VERTEX_SHADER, vsSrc, what), fs = Compile(GL_FRAGMENT_SHADER, fsSrc, what);
            uint p = glCreateProgram(); glAttachShader(p, vs); glAttachShader(p, fs);
            glLinkProgram(p);
            int ok; glGetProgramiv(p, GL_LINK_STATUS, out ok);
            if (ok == 0) { var sb = new StringBuilder(8192); int n; glGetProgramInfoLog(p, sb.Capacity, out n, sb); throw new InvalidOperationException("shaders for " + what + " did not link: " + sb); }
            glDeleteShader(vs); glDeleteShader(fs);
            _uloc.Remove(p);                  // (a reused program name: its old locations are not this one's)
            return p;
        }
        // UNIFORM LOCATIONS, ASKED ONCE (2026-10-13 performance audit): the passes looked ~200 names up every frame through
        // a string-marshalled driver call (PresentPass, PostCompose, WaterUniforms, DrawSet's "uSkip", the cube faces' "uOffY",
        // ...). A program's locations never change after it links, so each name is asked of the driver once and kept.
        readonly System.Collections.Generic.Dictionary<uint, System.Collections.Generic.Dictionary<string, int>> _uloc = new System.Collections.Generic.Dictionary<uint, System.Collections.Generic.Dictionary<string, int>>();
        int glGetUniformLocation(uint prog, string name)
        {
            System.Collections.Generic.Dictionary<string, int> d;
            if (!_uloc.TryGetValue(prog, out d)) { d = new System.Collections.Generic.Dictionary<string, int>(); _uloc[prog] = d; }
            int v; if (!d.TryGetValue(name, out v)) { v = glGetUniformLocationRaw(prog, name); d[name] = v; }
            return v;
        }

        // uniform locations
        int mView, mF, mNear, mTex, mMask, mFlip, mCentre, mLampOn, mLampRoom, mLampPower, mLampRange, mSpill, mHalo, mFpx, mCones, mLampC;
        int mFlash, mFlashC, mFlashRange, mLightDeep, mLightSoft, mSoftMax, mLampSoft, mLightDir, mLightCone, mLightTintM, mLightTintD;
        /// <summary>The muzzle flash: strength now (0 = none; the watcher sets it each frame and lets it decay), how far
        /// it reaches (units: half strength at this depth), and its colour.</summary>
        public float Flash, FlashRange = 420f; public int FlashColour = 0xFFC27A;
        /// <summary>How much of the room's own level a placed light's shadow also takes away (0 = only that light's).</summary>
        public float LightShadowDeep = 0.35f;
        /// <summary>Soft contact shadows for the placed lights: each light's size in world units (0 = hard edges as before),
        /// and the widest penumbra in shadow-map texels (also the margin kept free at each cube face's edge).</summary>
        public float LightSoft = 4f, SoftMaxTexels = 20f;
        /// <summary>The flashlight's size for its soft contact shadows (world units; 0 = the old even softening). The
        /// muzzle flash uses the flashlight's shadow views, so it follows.</summary>
        public float LampSoft = 3f;
        /// <summary>VOLUMETRIC FOG (per room): black air that absorbs with distance (up to VolMax opaque) and that the
        /// placed lights (shadowed, by their all-round maps) and the flashlight light up as they pass through it.
        /// VolScatter: how much of the fog scatters light (the rest only absorbs); VolLamp: the flashlight's share;
        /// VolAniso: forward scattering (bright looking toward a light); VolReach: a light's reach in the air (half as
        /// bright that far); VolFar / VolSteps: how far each pixel's air is marched, in how many steps.</summary>
        /// <summary>SPOTLIGHTS AND LIGHTS IN THE AIR (2026-10-08), per placed light: direction (world), cone inner/outer
        /// (degrees; outer 0 = all round), strength in the volumetric fog, its reach there (0 = the volume's), rays (0..1).</summary>
        readonly float[] _spot = NewSpots();
        static float[] NewSpots() { var s = new float[Raster.MaxLights * 8]; for (int i = 0; i < Raster.MaxLights; i++) { s[i * 8 + 1] = -1; s[i * 8 + 5] = 1; } return s; }      // (all round, air strength 1)
        readonly float[] _tint = NewTints();
        static float[] NewTints() { var s = new float[Raster.MaxLights * 5]; for (int i = 0; i < Raster.MaxLights; i++) { s[i * 5] = 1; s[i * 5 + 1] = 1; s[i * 5 + 2] = 1; s[i * 5 + 3] = 0; s[i * 5 + 4] = 1; } return s; }
        /// <summary>A light's colour shifting with distance: multiplied by (mr, mg, mb) from `from` to `to` units out.</summary>
        public void SetLightTint(int i, float mr, float mg, float mb, float from, float to)
        { if (i < 0 || i >= Raster.MaxLights) return; int b = i * 5; _tint[b] = mr; _tint[b + 1] = mg; _tint[b + 2] = mb; _tint[b + 3] = from; _tint[b + 4] = Math.Max(from + 0.01f, to); }
        /// <summary>Light i always takes one of the air's four places (the nearest otherwise), whatever lights are nearer.</summary>
        public void SetAirFirst(int i, bool on) { if (i >= 0 && i < Raster.MaxLights) _airFirst[i] = on; }
        readonly bool[] _airFirst = new bool[Raster.MaxLights];
        /// <summary>Light i lights only the side of each face the eye is on ("oneSided": sunlight outside a window lights the
        /// room through it, not the wall's inner face from behind). ClearLightSpots puts every light back to both sides.</summary>
        /// <summary>The placed lights light the AIR only inside this world box (the room's bounds: BAPTIST's sun outside its
        /// windows lit the open sky above the walls). Off = everywhere.</summary>
        public bool AirBoxOn; public readonly float[] AirLo = new float[3], AirHi = new float[3];
        /// <summary>Light i reaches only what it sees through this world box (a window's opening: BAPTIST's sun, 2026-10-14);
        /// on = false takes it off. ClearLightSpots takes every gate off.</summary>
        public void SetLightGate(int i, bool on, float x0, float y0, float z0, float x1, float y1, float z1)
        {
            if (i < 0 || i >= Raster.MaxLights) return; int g = i * 7;
            _gate[g] = on ? 1f : 0f; _gate[g + 1] = Math.Min(x0, x1); _gate[g + 2] = Math.Min(y0, y1); _gate[g + 3] = Math.Min(z0, z1); _gate[g + 4] = Math.Max(x0, x1); _gate[g + 5] = Math.Max(y0, y1); _gate[g + 6] = Math.Max(z0, z1);
        }
        readonly float[] _gate = new float[Raster.MaxLights * 7];
        readonly float[] _vGLo = new float[16], _vGHi = new float[12], _vLW = new float[12];
        public void SetLightOneSided(int i, bool on) { if (i >= 0 && i < Raster.MaxLights) _oneSided[i] = on; }
        readonly bool[] _oneSided = new bool[Raster.MaxLights];
        /// <summary>WALL WASHES (2026-10-14, Josh, CHAMBNEW): steady spotlights with no shadow, on top of the placed lights
        /// (a room's "lights" entries with "wash": true). Per wash, world space: x y z, range, r g b (colour x strength),
        /// direction (unit), cone inner/outer in degrees. Up to MaxWashes; null or n 0 = none.</summary>
        public void SetWashes(float[] w, int n)
        {
            _washN = 0; if (w == null) return;
            n = Math.Max(0, Math.Min(Math.Min(n, MaxWashes), w.Length / 12));
            for (int i = 0; i < n; i++)
            {
                int s = i * 12, b = i * WashStride;
                float dx = w[s + 7], dy = w[s + 8], dz = w[s + 9], l = (float)Math.Sqrt(dx * dx + dy * dy + dz * dz); if (l < 1e-6f) { dx = 0; dy = 1; dz = 0; l = 1; }
                for (int k = 0; k < 7; k++) _wash[b + k] = w[s + k];
                _wash[b + 7] = dx / l; _wash[b + 8] = dy / l; _wash[b + 9] = dz / l;
                float o = Math.Max(1f, Math.Min(w[s + 11], 89f)), inn = Math.Max(0f, Math.Min(w[s + 10], o - 0.5f));
                _wash[b + 10] = (float)Math.Cos(inn * Math.PI / 180); _wash[b + 11] = (float)Math.Cos(o * Math.PI / 180);
            }
            _washN = n;
        }
        public const int MaxWashes = 16; const int WashStride = 12;
        /// <summary>SHOT IMPACTS (Josh, 2026-10-14): a scorch where a shot hit -- point, the surface's normal, radius (units); the
        /// newest 16 are kept, each fading over ScorchLife seconds (by Time). ImpactK (0..1, the watcher eases it to 0 over a
        /// fraction of a second) lights the spot: a brief warm glow off the surface, as one more wall wash.</summary>
        public void AddScorch(float x, float y, float z, float nx, float ny, float nz, float radius)
        {
            int b = _scNext * 8; _sc[b] = x; _sc[b + 1] = y; _sc[b + 2] = z; _sc[b + 3] = radius; _sc[b + 4] = nx; _sc[b + 5] = ny; _sc[b + 6] = nz; _sc[b + 7] = Time;
            _scNext = (_scNext + 1) % 16; if (_scN < 16) _scN++;
            ImpactAt[0] = x + nx * 6f; ImpactAt[1] = y + ny * 6f; ImpactAt[2] = z + nz * 6f; ImpactAt[3] = nx; ImpactAt[4] = ny; ImpactAt[5] = nz;
        }
        public void ClearScorches() { _scN = 0; _scNext = 0; ImpactK = 0f; }
        public float ScorchLife = 30f, ImpactK, ImpactPower = 2.2f, ImpactRange = 70f; public int ImpactColour = 0xFF9A40;
        public readonly float[] ImpactAt = new float[6];
        readonly float[] _sc = new float[16 * 8]; int _scN, _scNext;
        readonly float[] _wash = new float[MaxWashes * WashStride]; int _washN;
        public int WashCount { get { return _washN; } }
        public void ClearLightSpots() { Array.Clear(_airFirst, 0, _airFirst.Length); Array.Clear(_oneSided, 0, _oneSided.Length); Array.Clear(_gate, 0, _gate.Length); for (int i = 0; i < Raster.MaxLights; i++) SetLightTint(i, 1, 1, 1, 0, 1); for (int i = 0; i < Raster.MaxLights; i++) { int b = i * 8; _spot[b] = 0; _spot[b + 1] = -1; _spot[b + 2] = 0; _spot[b + 3] = 0; _spot[b + 4] = 0; _spot[b + 5] = 1; _spot[b + 6] = 0; _spot[b + 7] = 0; } }
        public void SetLightSpot(int i, float dx, float dy, float dz, float innerDeg, float outerDeg, float air, float airReach, float rays)
        {
            if (i < 0 || i >= Raster.MaxLights) return; int b = i * 8; float l = (float)Math.Sqrt(dx * dx + dy * dy + dz * dz); if (l < 1e-6f) { dx = 0; dy = -1; dz = 0; l = 1; }
            _spot[b] = dx / l; _spot[b + 1] = dy / l; _spot[b + 2] = dz / l; _spot[b + 3] = innerDeg; _spot[b + 4] = outerDeg; _spot[b + 5] = air; _spot[b + 6] = airReach; _spot[b + 7] = rays;
        }
        /// <summary>The fog's march at half size each way, brought back depth-aware (2026-10-08 optimisation: ~4x less of the
        /// heaviest pass). False = every pixel marched, as before.</summary>
        public bool VolHalf = true;
        uint _volTex, _volFbo; int _volW, _volH;
        const uint GL_RGBA16F = 0x881A, GL_RGBA = 0x1908;
        public bool VolOn; public float VolDensity = 0.0035f, VolMax = 0.8f, VolScatter = 0.6f, VolLamp = 1f, VolAniso = 0.45f, VolReach = 110f, VolFar = 700f;
        public int VolSteps = 24, VolColor = 0;
        /// <summary>How much the flashlight thins the fog inside its cone (0..1), as much as the lamp is on.</summary>
        public float VolCut = 0.65f;
        /// <summary>THE PLACED LIGHTS CUT THROUGH TOO (Josh, 2026-10-09: from a distance the fog 'swallows' the torch and the
        /// shaft). VolLit: how much more of a surface lit by them (or a flame) comes through the fog, at full light (0..1);
        /// VolLitAir: how much less their glow in the air is absorbed on its way to the eye.</summary>
        public float VolLit = 0.85f, VolLitAir = 0.7f;
        readonly int[] _air = new int[4];
        /// <summary>How far round an all-round placed light (a torch) its light clears the fog (units; spots: their beam).</summary>
        public float LitReach = 110f;
        int _vN; readonly float[] _vP = new float[16], _vC = new float[12], _vF = new float[12], _vAx = new float[54], _vB = new float[36], _vK = new float[16], _vR = new float[4], _vM = new float[12], _vT = new float[8]; readonly uint[] _vTex = new uint[4];
        int mLampMaps, mLampMap0, mLampMap1, mLampOff, mLampMapF, mLampMapSize, mShadow, mSFade;
        int mNorm, mRelief, mNormLod, mNormBands, mNormFine, mNormMid, mNormTile, mPixelMip, mMipK, mNormMipK, mReliefGain, mReliefTint, mReliefOp, mDetail, mDetailScale, mDetailAO, mDetailRough, mDetailOct;
        int mShineOn, mShine, mGloss, mMetal, mShineVary, mLampPos, mMat, mMatHas, mGlowK;
        int mWetOn, mWetK, mWetA, mWetB, mWetC, mGround, mGroundBox, mTime, mReliefK, mMixOn, mMixScale, mPomK, mPomOn, mHeight, mMatz, mMatC, mMatF, mMatX;
        // the lamp's shadow maps as this frame's picture used them (the compose lights the air with them)
        int _cMaps; readonly float[] _cOff = new float[4], _cF = new float[3]; readonly int[] _cSize = new int[2]; readonly uint[] _cTex = new uint[2];
        int mCubeAx, mLightCount, mLightP, mLightC, mLightMapOn, mLightMap0, mLightAx, mLightMapF, mFogOn, mFog, mFogCol, mRefl, mDim, mSurf;
        int dView, dF, dNear, dMask, dFlip, dNoMask, eWH, eNear, eCol, eDark, sPic, sK, sSize, cPic, cScreen, cMap, cKey, cBand, cVisor, cK, cSize, cBlack;
        void LocateUniforms()
        {
            uint p = _pMain;
            mView = glGetUniformLocation(p, "uView"); mF = glGetUniformLocation(p, "uF"); mNear = glGetUniformLocation(p, "uNear");
            mTex = glGetUniformLocation(p, "uTex"); mMask = glGetUniformLocation(p, "uMask"); mFlip = glGetUniformLocation(p, "uFlip"); mCentre = glGetUniformLocation(p, "uCentre");
            mLampOn = glGetUniformLocation(p, "uLampOn"); mLampRoom = glGetUniformLocation(p, "uLampRoom"); mLampPower = glGetUniformLocation(p, "uLampPower"); mLampRange = glGetUniformLocation(p, "uLampRange");
            mSpill = glGetUniformLocation(p, "uSpill"); mHalo = glGetUniformLocation(p, "uHalo"); mFpx = glGetUniformLocation(p, "uFpx"); mCones = glGetUniformLocation(p, "uCones"); mLampC = glGetUniformLocation(p, "uLampC");
            mLampMaps = glGetUniformLocation(p, "uLampMaps"); mLampMap0 = glGetUniformLocation(p, "uLampMap[0]"); mLampMap1 = glGetUniformLocation(p, "uLampMap[1]");
            mLampOff = glGetUniformLocation(p, "uLampOff[0]"); mLampMapF = glGetUniformLocation(p, "uLampMapF"); mLampMapSize = glGetUniformLocation(p, "uLampMapSize");
            mShadow = glGetUniformLocation(p, "uShadow"); mSFade = glGetUniformLocation(p, "uSFade");
            mFlash = glGetUniformLocation(p, "uFlash"); mFlashC = glGetUniformLocation(p, "uFlashC"); mFlashRange = glGetUniformLocation(p, "uFlashRange"); mLightDeep = glGetUniformLocation(p, "uLightDeep"); mLightSoft = glGetUniformLocation(p, "uLightSoft"); mSoftMax = glGetUniformLocation(p, "uSoftMax"); mLampSoft = glGetUniformLocation(p, "uLampSoft"); mLightDir = glGetUniformLocation(p, "uLightDir[0]"); mLightCone = glGetUniformLocation(p, "uLightCone[0]"); mLightTintM = glGetUniformLocation(p, "uLightTintM[0]"); mLightTintD = glGetUniformLocation(p, "uLightTintD[0]");
            mLightCount = glGetUniformLocation(p, "uLightCount"); mLightP = glGetUniformLocation(p, "uLightP[0]"); mLightC = glGetUniformLocation(p, "uLightC[0]");
            mLightMapOn = glGetUniformLocation(p, "uLightMapOn[0]"); mLightMap0 = glGetUniformLocation(p, "uLightMap[0]"); mLightAx = glGetUniformLocation(p, "uLightAx[0]"); mLightMapF = glGetUniformLocation(p, "uLightMapF[0]"); mCubeAx = glGetUniformLocation(p, "uCubeAx[0]");
            mFogOn = glGetUniformLocation(p, "uFogOn"); mFog = glGetUniformLocation(p, "uFog"); mFogCol = glGetUniformLocation(p, "uFogCol");
            mRefl = glGetUniformLocation(p, "uRefl"); mDim = glGetUniformLocation(p, "uDim"); mSurf = glGetUniformLocation(p, "uSurf");
            mNorm = glGetUniformLocation(p, "uNorm"); mRelief = glGetUniformLocation(p, "uRelief"); mReliefK = glGetUniformLocation(p, "uReliefK"); mNormLod = glGetUniformLocation(p, "uNormLod");
            mNormBands = glGetUniformLocation(p, "uNormBands"); mNormFine = glGetUniformLocation(p, "uNormFine"); mNormMid = glGetUniformLocation(p, "uNormMid"); mNormTile = glGetUniformLocation(p, "uNormTile");
            mPixelMip = glGetUniformLocation(p, "uPixelMip"); mMipK = glGetUniformLocation(p, "uMipK"); mNormMipK = glGetUniformLocation(p, "uNormMipK"); mReliefGain = glGetUniformLocation(p, "uReliefGain"); mReliefTint = glGetUniformLocation(p, "uReliefTint"); mReliefOp = glGetUniformLocation(p, "uReliefOp");
            mDetail = glGetUniformLocation(p, "uDetail"); mDetailScale = glGetUniformLocation(p, "uDetailScale"); mDetailAO = glGetUniformLocation(p, "uDetailAO");
            mDetailRough = glGetUniformLocation(p, "uDetailRough"); mDetailOct = glGetUniformLocation(p, "uDetailOct");
            mShineOn = glGetUniformLocation(p, "uShineOn"); mShine = glGetUniformLocation(p, "uShine"); mGloss = glGetUniformLocation(p, "uGloss"); mMetal = glGetUniformLocation(p, "uMetal");
            mShineVary = glGetUniformLocation(p, "uShineVary"); mLampPos = glGetUniformLocation(p, "uLampPos"); mMat = glGetUniformLocation(p, "uMat"); mMatHas = glGetUniformLocation(p, "uMatHas"); mGlowK = glGetUniformLocation(p, "uGlowK");
            mWetOn = glGetUniformLocation(p, "uWetOn"); mWetK = glGetUniformLocation(p, "uWetK"); mWetA = glGetUniformLocation(p, "uWetA"); mWetB = glGetUniformLocation(p, "uWetB"); mWetC = glGetUniformLocation(p, "uWetC");
            mGround = glGetUniformLocation(p, "uGround"); mGroundBox = glGetUniformLocation(p, "uGroundBox"); mTime = glGetUniformLocation(p, "uTime");
            mMixOn = glGetUniformLocation(p, "uMixOn"); mMixScale = glGetUniformLocation(p, "uMixScale"); mPomK = glGetUniformLocation(p, "uPomK"); mPomOn = glGetUniformLocation(p, "uPomOn"); mHeight = glGetUniformLocation(p, "uHeight"); mMatz = glGetUniformLocation(p, "uMatz"); mMatC = glGetUniformLocation(p, "uMatC"); mMatF = glGetUniformLocation(p, "uMatF"); mMatX = glGetUniformLocation(p, "uMatX");
            p = _pDepth;
            dView = glGetUniformLocation(p, "uView"); dF = glGetUniformLocation(p, "uF"); dNear = glGetUniformLocation(p, "uNear");
            dMask = glGetUniformLocation(p, "uMask"); dFlip = glGetUniformLocation(p, "uFlip"); dNoMask = glGetUniformLocation(p, "uNoMask");
            p = _pMote;
            eWH = glGetUniformLocation(p, "uWH"); eNear = glGetUniformLocation(p, "uNear"); eCol = glGetUniformLocation(p, "uCol"); eDark = glGetUniformLocation(p, "uDark");
            p = _pSharp; sPic = glGetUniformLocation(p, "uPic"); sK = glGetUniformLocation(p, "uK"); sSize = glGetUniformLocation(p, "uSize");
            p = _pComp; cPic = glGetUniformLocation(p, "uPic"); cScreen = glGetUniformLocation(p, "uScreen"); cMap = glGetUniformLocation(p, "uMap");
            cKey = glGetUniformLocation(p, "uKey"); cBlack = glGetUniformLocation(p, "uBlack"); cBand = glGetUniformLocation(p, "uBand"); cVisor = glGetUniformLocation(p, "uVisor"); cK = glGetUniformLocation(p, "uK"); cSize = glGetUniformLocation(p, "uSize");
        }
        // texture units: 0 colour, 1 holes, 2-3 lamp maps, 4-11 light maps, 12 the depth copy (15 the bounce, 16 the companion maps)
        const int UNIT_MAP = 19; public bool MapUnitOk;      // (the map layer, for the compose)
        const int UNIT_LAMP = 2, UNIT_LIGHT = 4, UNIT_SURF = 12, UNIT_NORM = 13, UNIT_REFL = 14, UNIT_MAT = 16, UNIT_GROUND = 17, UNIT_HEIGHT = 18;

        // ---- lighting: a copy of the processor renderer's settings, taken every frame ---------
        bool _lampOn; float _lampRoom, _lampPower, _lampRange = 550f, _spill, _halo, _cIn, _cOut, _cHIn, _cHOut, _lampCx, _lampCy;
        bool _fogOn; float _fogNear, _fogFar, _fogMax; int _fogColor;
        float _sBias = 0.02f, _sSoft = 1f, _sDark = 0.3f, _sNear = 140f, _sFar = 900f, _lsBias = 0.03f;
        int _nLights; readonly float[] _lightsW = new float[Raster.MaxLights * 8];
        /// <summary>Take the lamp, its shadows' settings, fog and placed lights exactly as they stand
        /// on `r` (the watcher keeps setting them there: the lamp's fade and aim, the torch's
        /// flicker, the room's fog).</summary>
        public void CopyLighting(Raster r)
        {
            _lampOn = r.Lamp && r.LightTab != null && r.Shade == null;
            _lampRoom = r.LampRoom; _lampPower = r.LampPower; _lampRange = r.LampRange; _spill = r.LampSpill; _halo = r.LampHalo;
            _cIn = (float)Math.Cos(r.LampInnerDeg * Math.PI / 180); _cOut = (float)Math.Cos(r.LampOuterDeg * Math.PI / 180);
            _cHIn = (float)Math.Cos(r.LampHaloInnerDeg * Math.PI / 180); _cHOut = (float)Math.Cos(r.LampHaloDeg * Math.PI / 180);
            _lampCx = r.LampCx; _lampCy = r.LampCy;
            _sBias = r.ShadowBias; _sSoft = r.ShadowSoft; _sDark = r.ShadowDark; _sNear = r.ShadowNear; _sFar = r.ShadowFar; _lsBias = r.LightShadowBias;
            _fogOn = r.Fog32 && r.Fog32Far > r.Fog32Near; _fogNear = r.Fog32Near; _fogFar = r.Fog32Far; _fogMax = r.Fog32Max; _fogColor = r.FogColor32;
            _nLights = Math.Min(r.LightCount, Raster.MaxLights); _nRoomLights = _nLights;
            Array.Copy(r.Lights, _lightsW, Raster.MaxLights * 8);
            MipBias = r.MipBias;
        }

        // ---- shadow views, set for the next Draw -----------------------------------------------
        class Slot { public uint Fbo, Tex; public int W, H; public float[] World = new float[16]; public float FocalPx, Ox, Oy; public bool On, Cube; public int Face; }
        readonly Slot[] _slots = new Slot[2 + Raster.MaxLights];
        Slot EnsureSlot(int i, int w, int h)
        {
            var s = _slots[i];
            if (s == null) { s = new Slot(); _slots[i] = s; }
            if (s.Tex == 0 || s.W != w || s.H != h)
            {
                var ids = new uint[1];
                if (s.Tex != 0) glDeleteTextures(1, new[] { s.Tex });
                if (s.Fbo == 0) { glGenFramebuffers(1, ids); s.Fbo = ids[0]; }
                glGenTextures(1, ids); s.Tex = ids[0];
                glBindTexture(GL_TEXTURE_2D, s.Tex);
                glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_DEPTH_COMPONENT32F, w, h, 0, GL_DEPTH_COMPONENT, GL_FLOAT, IntPtr.Zero);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_CLAMP_TO_EDGE);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
                glBindFramebuffer(GL_FRAMEBUFFER, s.Fbo);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, s.Tex, 0);
                glDrawBuffer(GL_NONE); glReadBuffer(GL_NONE);
                Complete("a shadow view");
                s.W = w; s.H = h;
            }
            return s;
        }
        /// <summary>The helmet lamp's view for its shadows (i = 0, or 1 for the second of a pair):
        /// its camera (the player's orientation, moved by ox, oy), map size and focal length --
        /// what the watcher hands Raster.SetShadow. Drawn by the next Draw, from its geometry.</summary>
        public void SetLampShadow(int i, float[] world16, int w, int h, float focalPx, float ox, float oy)
        {
            if (i < 0 || i > 1 || world16 == null || world16.Length != 16) throw new ArgumentException("lamp shadow: slot 0 or 1 and a 4x4 camera");
            var s = EnsureSlot(i, w, h);
            Array.Copy(world16, s.World, 16); s.FocalPx = focalPx; s.Ox = ox; s.Oy = oy; s.On = true;
        }
        /// <summary>A placed light's view for its shadows: where it is, its right/up/forward
        /// (Raster.LastBasis after LookAt), a square map and its focal length.</summary>
        public void SetLightShadow(int li, float x, float y, float z, float[] basis9, int size, float focalPx)
        {
            if (li < 0 || li >= Raster.MaxLights || basis9 == null || basis9.Length < 9) throw new ArgumentException("light shadow: light 0-7 and its 9 axis numbers");
            var s = EnsureSlot(2 + li, size, size);
            float[] m = s.World;
            for (int r = 0; r < 3; r++) { m[r * 4] = basis9[r * 3]; m[r * 4 + 1] = basis9[r * 3 + 1]; m[r * 4 + 2] = basis9[r * 3 + 2]; m[r * 4 + 3] = 0f; }
            m[12] = x; m[13] = y; m[14] = z; m[15] = 1f;
            s.FocalPx = focalPx; s.Ox = 0; s.Oy = 0; s.On = true; s.Cube = false;
        }
        /// <summary>A placed light's shadows ALL ROUND (2026-10-08): six 90-degree views from (x, y, z), each `face`
        /// square, in one map 3 faces across and 2 down. Unlike SetLightShadow's single view there is no edge where its
        /// shadows stop.</summary>
        public void SetLightCube(int li, float x, float y, float z, int face)
        {
            if (li < 0 || li >= Raster.MaxLights || face < 16) throw new ArgumentException("light shadow: light 0-7 and a face size");
            var s = EnsureSlot(2 + li, face * 3, face * 2);
            float[] m = s.World;
            for (int k = 0; k < 16; k++) m[k] = k % 5 == 0 ? 1f : 0f;
            m[12] = x; m[13] = y; m[14] = z;
            s.FocalPx = face * 0.5f - (LightSoft > 0 ? SoftMaxTexels + 3f : 3f);      // 90 degrees across the face, less a margin at each edge for the soft taps (the widest penumbra)
            s.Face = face; s.Ox = 0; s.Oy = 0; s.On = true; s.Cube = true;
        }
        // the six faces' right/up/forward (world): +X -X +Y -Y +Z -Z
        static readonly float[][] CubeFaces = MakeCubeFaces();
        static float[][] MakeCubeFaces()
        {
            float[][] fw = { new[] { 1f, 0, 0 }, new[] { -1f, 0, 0 }, new[] { 0, 1f, 0 }, new[] { 0, -1f, 0 }, new[] { 0, 0, 1f }, new[] { 0, 0, -1f } };
            var r = new float[6][];
            for (int i = 0; i < 6; i++)
            {
                float[] f = fw[i], u = Math.Abs(f[1]) > 0.5f ? new[] { 0f, 0, 1f } : new[] { 0f, 1f, 0 };
                float[] rt = { u[1] * f[2] - u[2] * f[1], u[2] * f[0] - u[0] * f[2], u[0] * f[1] - u[1] * f[0] };     // up x forward
                float[] up = { f[1] * rt[2] - f[2] * rt[1], f[2] * rt[0] - f[0] * rt[2], f[0] * rt[1] - f[1] * rt[0] };  // forward x right
                r[i] = new[] { rt[0], rt[1], rt[2], up[0], up[1], up[2], f[0], f[1], f[2] };
            }
            return r;
        }

        // ---- water and dust, set for the next Draw -------------------------------------------
        public float WaterKeep = 0.65f, WaterDim = 0.72f;
        /// <summary>MODERN WATER (Josh, 2026-10-08, SPAROOM: 'make it look like modern water ... a shiny, water effect surface'
        /// and 'light sources beneath this water surface ... water-like light projections on the walls above'). Per room,
        /// from its "water" block. On: the reflection is bent by moving ripples and is as strong as the angle makes it
        /// (Fresnel: strong at a glance, little looking straight down) instead of a fixed share; the flashlight and placed
        /// lights glint off the ripples; light comes up out of the water (WaterGlowColor: an even WaterGlowBase plus the
        /// lamps under it, AddWaterLight), brightening the water's own specks (WaterDots) and throwing moving caustics and a
        /// soft fill (CausFill) onto the walls and undersides above it, fading over CausHeight units.</summary>
        public bool WaterFx;
        public int WaterGlowColor = 0x30D8C8;
        public float WaterGlow = 0.35f, WaterGlowBase = 0.5f, WaterDots = 1.2f, WaterShine = 1f, WaterF0 = 0.04f, WaterSpec = 1f, WaterDistort = 60f, WaterLightSpec = 1f;
        public float RippleSlope = 0.15f, RippleSize = 34f, RippleSpeed = 0.5f;
        /// <summary>Rings where drips land on the water (Particles.GatherDrops): x, z, height, age per drip; DropRipple = how strong.</summary>
        public float DropRipple = 1f;
        readonly float[] _dropsGl = new float[16 * 4]; int _dropsN;
        public void SetDrops(float[] xzhAge, int n)
        {
            _dropsN = Math.Max(0, Math.Min(16, n));
            for (int i = 0; i < _dropsN; i++) { _dropsGl[i * 4] = xzhAge[i * 4]; _dropsGl[i * 4 + 1] = xzhAge[i * 4 + 1]; _dropsGl[i * 4 + 2] = Time - xzhAge[i * 4 + 3]; _dropsGl[i * 4 + 3] = xzhAge[i * 4 + 2]; }
        }
        public float CausStrength = 0.55f, CausSize = 38f, CausSpeed = 0.45f, CausHeight = 110f, CausFill = 0.18f;
        readonly float[] _wSpot = new float[16]; int _wSpotN;
        public void ClearWaterLights() { _wSpotN = 0; _wCutN = 0; }
        readonly float[] _wCut = new float[16]; int _wCutN;
        /// <summary>A floor-plan box (x0, z0)-(x1, z1) the water's light does not reach (a hallway off the pool room).</summary>
        public void AddWaterCut(float x0, float z0, float x1, float z1)
        { if (_wCutN >= 4) return; int b = _wCutN * 4; _wCut[b] = Math.Min(x0, x1); _wCut[b + 1] = Math.Min(z0, z1); _wCut[b + 2] = Math.Max(x0, x1); _wCut[b + 3] = Math.Max(z0, z1); _wCutN++; }
        /// <summary>A lamp under the water at (x, z): a pool of glow `radius` across, `power` x the even glow's unit.</summary>
        public void AddWaterLight(float x, float z, float radius, float power)
        { if (_wSpotN >= 4) return; int b = _wSpotN * 4; _wSpot[b] = x; _wSpot[b + 1] = z; _wSpot[b + 2] = Math.Max(1f, radius); _wSpot[b + 3] = power; _wSpotN++; }
        // this frame's pools: their floor-plan boxes (x0, z0, x1, z1) and heights, for the light they throw
        readonly float[] _wBox = new float[16], _wYs = new float[4]; int _wBoxN;
        readonly List<int[]> _waterTris = new List<int[]>(); readonly List<float> _waterY = new List<float>();
        /// <summary>One pool (or a group at one level): its triangles as vertex indices into the
        /// geometry the next Draw is given, and the height to mirror the room through.</summary>
        public void AddWater(int[] triVerts, float planeY)
        {
            if (triVerts == null || triVerts.Length < 3) return;
            _waterTris.Add(triVerts); _waterY.Add(planeY);
        }
        float[] _motes = new float[0]; int _moteN; int _moteCol, _moteDark;
        /// <summary>The dust for the next Draw: Motes.Gather's output, 6 floats a mote.</summary>
        public void SetMotes(float[] data, int n, int color, int colorDark)
        {
            if (data == null || n <= 0) { _moteN = 0; return; }
            if (_motes.Length < n * 6) _motes = new float[n * 6];
            Array.Copy(data, _motes, n * 6); _moteN = n; _moteCol = color; _moteDark = colorDark;
        }

        // ---- camera: exactly Raster's ---------------------------------------------------------
        public void SetVerticalFov(double degrees) { _focal = (float)(1.0 / Math.Tan(degrees * Math.PI / 360.0)); }
        public float FocalPx { get { return _focal * VHf * 0.5f; } }
        /// <summary>Rows of the picture that are the VIEW: the projection is centred in them; rows below carry
        /// on with the same projection (the 3D under the widescreen panel). 0 = all of it. As Raster.ViewRows.</summary>
        public int ViewRows;
        float VHf { get { return ViewRows > 0 ? ViewRows : H; } }
        // clip-space y offset that puts the view's centre at row VHf/2 of an H-row picture
        float OffY { get { return VHf / H - 1f; } }
        /// <summary>The camera's WORLD matrix as the engine holds it (rows right, up, forward, position).</summary>
        public void SetCameraWorld(float[] m) { _view = ViewOf(m); Array.Copy(m, _camWorld, 16); }
        readonly float[] _camWorld = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
        static float[] ViewOf(float[] m)
        {
            if (m == null || m.Length != 16) throw new ArgumentException("need a 4x4");
            float[] v = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) v[i * 4 + j] = m[j * 4 + i];
            float px = m[12], py = m[13], pz = m[14];
            v[12] = -(px * m[0] + py * m[1] + pz * m[2]);
            v[13] = -(px * m[4] + py * m[5] + pz * m[6]);
            v[14] = -(px * m[8] + py * m[9] + pz * m[10]);
            return v;
        }

        // ---- textures --------------------------------------------------------------------------
        /// <summary>Make sure every texture of a room is on the card (each is uploaded once and
        /// shared between rooms, like the Tex objects themselves). Returns how many were new.</summary>
        public int Upload(Raster.Tex[] texes) { return UploadSome(texes, int.MaxValue); }
        /// <summary>At most `max` of a room's textures that are not on the card yet (or lack the sharp relief map this room
        /// wants) go up now; the rest stay for later. Over budget, the least recently used textures of OTHER rooms are
        /// dropped first. Every texture named is marked as used now. Returns how many went up. (The watcher uploads a new
        /// room a few at a time under its loading cover, so the first frame of the room never stalls; Draw does the rest.)</summary>
        public int UploadSome(Raster.Tex[] texes, int max)
        {
            var sw = Stopwatch.StartNew(); int n = 0; long stamp = ++_useStamp;
            if (TextureBytes > MaxTextureBytes) Evict(texes, MaxTextureBytes * 85 / 100);
            foreach (var t in texes)
            {
                if (t == null) continue;
                GTex have;
                if (_tex.TryGetValue(t, out have))
                {   // already here (shared with a room met earlier): give it a sharp map if this room wants them
                    have.Used = stamp;
                    if (ReliefSharpBuild && have.NormHi == 0 && n < max) { long b0 = have.Bytes; have.NormHi = SharpFor(have, t); have.SharpB = have.Bytes - b0; TextureBytes += have.Bytes - b0; n++; }
                    continue;
                }
                if (n >= max) continue;
                var g = Make(t); g.Used = stamp; _tex[t] = g; n++;
            }
            TexturesUploaded += n; LastUploadMs = sw.Elapsed.TotalMilliseconds;
            return n;
        }
        /// <summary>How many of these textures still have to go up (or still want their sharp relief map).</summary>
        public int MissingCount(Raster.Tex[] texes)
        {
            int n = 0; var seen = new HashSet<Raster.Tex>();
            foreach (var t in texes)
            {
                if (t == null || !seen.Add(t)) continue;
                GTex have; if (!_tex.TryGetValue(t, out have) || (ReliefSharpBuild && have.NormHi == 0)) n++;
            }
            return n;
        }
        /// <summary>THE CARD AS A CACHE (Josh, 2026-10-12: "cache these textures per game session so they don't have to load
        /// everytime a player enters a room"): over budget, drop the least recently used textures that this room does not use,
        /// until at most `target` bytes are held -- so the rooms visited last stay on the card. (It used to drop EVERY texture,
        /// and a 4K room is 3.5-4.6 GB with its relief maps: by the third room each entry uploaded all of its art again.)</summary>
        void Evict(Raster.Tex[] keep, long target)
        {
            var k = new HashSet<Raster.Tex>(); foreach (var t in keep) if (t != null) k.Add(t);
            var old = new List<KeyValuePair<Raster.Tex, GTex>>();
            foreach (var kv in _tex) if (!k.Contains(kv.Key)) old.Add(kv);
            old.Sort((a, b) => a.Value.Used.CompareTo(b.Value.Used));
            foreach (var kv in old)
            {
                if (TextureBytes <= target) break;
                var g = kv.Value;
                glDeleteTextures(6, new[] { g.Rgb, g.Mask, g.Norm, g.NormHi, g.Mat, g.Height });     // (0 is ignored)
                TextureBytes -= g.Bytes; if (g.NormHi != 0) { SharpBytes -= g.SharpB; SharpMaps--; }
                if (g.Height != 0) { HeightBytes -= g.HeightB; HeightMaps--; }
                _tex.Remove(kv.Key); Evicted++;
            }
        }
        GTex Make(Raster.Tex t)
        {
            var g = new GTex(); var ids = new uint[1];
            // the colour, with the very same half-size copies Raster samples
            glGenTextures(1, ids); g.Rgb = ids[0];
            glBindTexture(GL_TEXTURE_2D, g.Rgb);
            if (t.Rgb != null && t.Rgb.Length > 0)
            {
                for (int l = 0; l < t.Rgb.Length; l++)
                {
                    var lv = t.Rgb[l];
                    glTexImage2D(GL_TEXTURE_2D, l, (int)GL_RGBA8, lv.W, lv.H, 0, GL_BGRA, GL_UNSIGNED_BYTE, lv.Px);
                    g.Bytes += (long)lv.W * lv.H * 4;
                }
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, t.Rgb.Length - 1);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR_MIPMAP_LINEAR);
            }
            else
            {
                // no colour prepared: a flat grey, so a missing texture is visible rather than a crash
                glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, 1, 1, 0, GL_BGRA, GL_UNSIGNED_BYTE, new[] { 0x808080 });
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR);
            }
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_REPEAT);
            // (no texture LOD bias: the shader works out the level itself, MipBias included, as Raster does)
            if (Anisotropy > 1f) glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, Anisotropy);
            // the sharp relief map where it is wanted (everywhere since 2026-10-07), else the first, half-size kind
            if (ReliefSharpBuild) { long b0 = g.Bytes; g.NormHi = SharpFor(g, t); g.SharpB = g.Bytes - b0; }
            else g.Norm = MakeRelief(g.Rgb, t, ref g.Bytes);
            // the holes: palette index 0, at the palette texture's own size, nearest texel -- as Raster decides them
            // (and the light from the artwork in its second channel: BuildArtLight)
            glGenTextures(1, ids); g.Mask = ids[0];
            glBindTexture(GL_TEXTURE_2D, g.Mask);
            glTexImage2DB(GL_TEXTURE_2D, 0, (int)GL_RG8, t.W, t.H, 0, GL_RG, GL_UNSIGNED_BYTE, MaskBytes(t));
            g.ArtSrc = t.ArtLight; g.IdxSrc = t.Idx;
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_REPEAT);
            g.Bytes += (long)t.W * t.H * 2;
            TextureBytes += g.Bytes;
            Check("uploading a texture");
            // its companion maps (smoothness, height, glow), when it has them (counted by MakeMat itself)
            if (MatUnitOk && t.MatPx != null) MakeMat(t, g);
            // its height map, for the parallax depth, if its material takes it (counted by MakeHeight itself)
            if (SurfacePom(t)) MakeHeight(t, g);
            return g;
        }
        // RELIEF MAPS, made on the card when a texture arrives: from the texture's own brightness,
        // with the broad light-and-shade the artists painted in taken away (fine detail minus a
        // heavily blurred copy), so what remains reads as relief -- mortar lines, cracks, grime --
        // and not as slopes. Half the colour's size, with its own mipmaps.
        uint MakeRelief(uint rgb, Raster.Tex t, ref long bytes)
        {
            var ids = new uint[1]; glGenTextures(1, ids); uint nt = ids[0];
            int aw = (t.Rgb != null && t.Rgb.Length > 0) ? t.Rgb[0].W : 1, ah = (t.Rgb != null && t.Rgb.Length > 0) ? t.Rgb[0].H : 1;
            int nw = Math.Max(4, aw / 2), nh = Math.Max(4, ah / 2);
            glBindTexture(GL_TEXTURE_2D, nt);
            glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_RGBA8, nw, nh, 0, GL_BGRA, GL_UNSIGNED_BYTE, IntPtr.Zero);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_REPEAT);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR_MIPMAP_LINEAR);
            int levels = 1 + (int)Math.Floor(Math.Log(Math.Max(nw, nh), 2));
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, levels - 1);
            glBindFramebuffer(GL_FRAMEBUFFER, _normFbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, nt, 0);
            glViewport(0, 0, nw, nh);
            glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST); glDisable(GL_BLEND); glDisable(GL_CULL_FACE); glColorMask(1, 1, 1, 1);
            glUseProgram(_pNorm); glBindVertexArray(_eVao);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, rgb);
            glUniform1i(glGetUniformLocation(_pNorm, "uAlb"), 0);
            glUniform2f(glGetUniformLocation(_pNorm, "uTexel"), 1f / nw, 1f / nh);
            float baseLod = (float)Math.Log((double)aw / nw, 2);
            glUniform1f(glGetUniformLocation(_pNorm, "uLodBase"), baseLod);
            glUniform1f(glGetUniformLocation(_pNorm, "uLodWide"), baseLod + 4f);
            glUniform1f(glGetUniformLocation(_pNorm, "uK"), (t.Rgb != null && t.Rgb.Length > 0) ? ReliefBuild : 0f);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glBindTexture(GL_TEXTURE_2D, nt); glGenerateMipmap(GL_TEXTURE_2D);
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glBindVertexArray(0);
            bytes += (long)nw * nh * 4 * 4 / 3;
            return nt;
        }
        const string FS_NORM = @"#version 400 core
uniform sampler2D uAlb; uniform vec2 uTexel; uniform float uLodBase, uLodWide, uK;
out vec4 oColor;
float lum(vec2 st, float lod) { return dot(textureLod(uAlb, st, lod).rgb, vec3(0.30, 0.59, 0.11)); }
float h(vec2 st) { return lum(st, uLodBase) - lum(st, uLodWide); }
void main() {
    vec2 st = gl_FragCoord.xy * uTexel;
    float hx = h(st + vec2(uTexel.x, 0.0)) - h(st - vec2(uTexel.x, 0.0));
    float hy = h(st + vec2(0.0, uTexel.y)) - h(st - vec2(0.0, uTexel.y));
    vec3 n = normalize(vec3(-hx * uK, -hy * uK, 1.0));
    oColor = vec4(n * 0.5 + 0.5, 1.0);
}";
        // THE SHARP MAPS (see ReliefSharp): full size, two channels, their own mipmaps
        // A texture's sharp relief map, from a companion HEIGHT map when it has one (Josh's own depth: what is raised and
        // what is sunk, not guessed from the paint's brightness), else from its colour as always
        uint SharpFor(GTex g, Raster.Tex t)
        {
            if (t.MatPx == null || (t.MatHas & 2) == 0 || t.MatW < 4 || t.MatH < 4) return MakeSharpRelief(g.Rgb, t, ref g.Bytes);
            var px = new int[t.MatPx.Length];
            for (int i = 0; i < px.Length; i++) { int h = (t.MatPx[i] >> 8) & 255; px[i] = unchecked((int)0xFF000000) | (h << 16) | (h << 8) | h; }
            var ids = new uint[1]; glGenTextures(1, ids); uint src = ids[0];
            glBindTexture(GL_TEXTURE_2D, src);
            glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, t.MatW, t.MatH, 0, GL_BGRA, GL_UNSIGNED_BYTE, px);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_REPEAT);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR_MIPMAP_LINEAR);
            glGenerateMipmap(GL_TEXTURE_2D);
            try { return MakeSharpRelief(src, t, ref g.Bytes, ReliefHeightK > 0f ? ReliefHeightK : ReliefSharpK); }
            finally { glDeleteTextures(1, new[] { src }); }
        }
        /// <summary>Which of these textures take the parallax depth now, and which the art's plank check keeps flat.</summary>
        public string ParallaxReport(Raster.Tex[] texes)
        {
            var on = new List<string>(); var planks = new List<string>(); var props = new List<string>(); var seen = new HashSet<Raster.Tex>();
            foreach (var t in texes)
            {
                if (t == null || !seen.Add(t) || t.Parallax <= 0f || t.Moves) continue;
                if (!t.ParallaxSet && !_pomShell.Contains(t)) { props.Add(t.Leaf); continue; }
                GTex g; if (!_tex.TryGetValue(t, out g) || g.Height == 0) continue;
                if (t.ParallaxSet || g.Grain <= ParallaxGrainMax) on.Add(t.Leaf); else planks.Add(string.Format("{0} ({1:N2})", t.Leaf, g.Grain));
            }
            return string.Format("{0} textures: {1}{2}{3}", on.Count, string.Join(", ", on), planks.Count > 0 ? "; kept flat as planks (grain): " + string.Join(", ", planks) : "", props.Count > 0 ? "; kept flat as not wall or floor: " + string.Join(", ", props) : "");
        }        // HEIGHT MAPS (the parallax depth): one channel, 1 = the face, 0 = ParallaxDepth below it, with its own mipmaps
        void MakeHeight(Raster.Tex t, GTex g)
        {
            if (g.Height != 0) { glDeleteTextures(1, new[] { g.Height }); g.Height = 0; g.Bytes -= g.HeightB; TextureBytes -= g.HeightB; HeightBytes -= g.HeightB; HeightMaps--; g.HeightB = 0; }
            g.HeightSrc = t.MatPx; g.HeightDone = true; g.Grain = 0f; g.HeightShade = t.ParallaxShade;
            if (!DepthUnitOk || t.Moves) return;
            var hsw = Stopwatch.StartNew(); int w, h; float grain; byte[] hb = HeightOf(t, out w, out h, out grain, t.ParallaxShade); HeightMs += hsw.Elapsed.TotalMilliseconds; g.Grain = grain; if (hb == null) return;
            var ids = new uint[1]; glGenTextures(1, ids); g.Height = ids[0];
            glBindTexture(GL_TEXTURE_2D, g.Height);
            glTexImage2DB(GL_TEXTURE_2D, 0, (int)GL_R8, w, h, 0, GL_RED, GL_UNSIGNED_BYTE, hb);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_REPEAT);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR_MIPMAP_LINEAR);
            if (Anisotropy > 1f) glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, Anisotropy);
            glGenerateMipmap(GL_TEXTURE_2D);
            g.HeightB = (long)w * h * 4 / 3; g.Bytes += g.HeightB; TextureBytes += g.HeightB; HeightBytes += g.HeightB; HeightMaps++;
            Check("uploading a height map");
        }
        /// <summary>A texture's height (0..255, 255 = the face): its companion height map where it has one (Josh's own depth, at
        /// most 1024 across), else its art's GROOVES (at most 512 across): narrow dark lines -- mortar, plank gaps, cracks, the
        /// joints between stones -- found as the art's brightness closed (dilated, then eroded, by a square ~1/128 of it across)
        /// minus the brightness, spread to full depth at the 98th percentile and softened a texel. Faces stay at the top: painted
        /// light and shade, and the carving painted into the art, are not taken for height (first tried 2026-10-12: brightness
        /// as height made cobbles shaggy and carved pillars shred). Null: no art to read.</summary>
        static byte[] HeightOf(Raster.Tex t, out int w, out int h, out float grain, float shade)
        {
            w = h = 0; grain = 0f;
            if (t.MatPx != null && (t.MatHas & 2) != 0 && t.MatW >= 4 && t.MatH >= 4 && t.MatPx.Length >= t.MatW * t.MatH)
            {
                int f = 1; while (t.MatW / f > 1024 || t.MatH / f > 1024) f *= 2;
                w = t.MatW / f; h = t.MatH / f; var o = new byte[w * h];
                for (int y = 0; y < h; y++)
                    for (int x = 0; x < w; x++)
                    {
                        int s = 0; for (int j = 0; j < f; j++) for (int i = 0; i < f; i++) s += (t.MatPx[(y * f + j) * t.MatW + x * f + i] >> 8) & 255;
                        o[y * w + x] = (byte)(s / (f * f));
                    }
                return o;
            }
            if (t.Rgb == null || t.Rgb.Length == 0) return null;
            int b = 0; while (b + 1 < t.Rgb.Length && (t.Rgb[b].W > 512 || t.Rgb[b].H > 512)) b++;
            var B = t.Rgb[b]; w = B.W; h = B.H; if (w < 8 || h < 8 || B.Px == null) return null;
            var L = new float[w * h];
            for (int i = 0; i < L.Length; i++) { int q = B.Px[i]; L[i] = 0.30f * ((q >> 16) & 255) + 0.59f * ((q >> 8) & 255) + 0.11f * (q & 255); }
            // the GRAIN: how much the art's brightness runs one way (its gradients' coherence, 0 none .. 1 all one way) -- planks
            // 0.52-0.65, cobbles and rock 0.02-0.22, carved stone walls up to 0.53 (measured 2026-10-12)
            { double xx = 0, yy = 0, xy = 0;
              for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
              { double ddx = L[y * w + (x + 1) % w] - L[y * w + (x + w - 1) % w], ddy = L[((y + 1) % h) * w + x] - L[((y + h - 1) % h) * w + x]; xx += ddx * ddx; yy += ddy * ddy; xy += ddx * ddy; }
              grain = (float)(Math.Sqrt((xx - yy) * (xx - yy) + 4 * xy * xy) / Math.Max(1e-9, xx + yy)); }
            int r = Math.Max(2, Math.Max(w, h) / 128);
            var cl = MinMax(MinMax(MinMax(MinMax(L, w, h, r, true, 1), w, h, r, false, 1), w, h, r, true, 0), w, h, r, false, 0);
            var g = new float[w * h]; for (int i = 0; i < g.Length; i++) g[i] = Math.Max(0f, cl[i] - L[i]);
            // a texel's softening (3x3), so the grooves' walls are not stairs
            var sg = MinMax(g, w, h, 1, true, 2); sg = MinMax(sg, w, h, 1, false, 2);
            var smp = new List<float>(sg.Length / 5 + 1); for (int i = 0; i < sg.Length; i += 5) smp.Add(sg[i]);
            smp.Sort(); float top = Math.Max(4f, smp[(int)(smp.Count * 0.98)]);
            var ob = new byte[w * h];
            if (shade <= 0f)
            {
                for (int i = 0; i < sg.Length; i++) ob[i] = (byte)(255 - Math.Max(0, Math.Min(255, (int)(sg[i] / top * 255f + 0.5f))));
                return ob;
            }
            // SHADING: the art's brightness, softened a little (r 2) minus a copy 16x broader (the painted light pool, a torch's
            // glow, taken away), spread 2..98% -- bright areas bulge, dark ones sink; then the grooves carved into it
            int rs = Math.Max(1, Math.Max(w, h) / 256), rb = Math.Max(4, Math.Max(w, h) / 16);
            var fine = MinMax(MinMax(L, w, h, rs, true, 2), w, h, rs, false, 2);
            var broad = MinMax(MinMax(L, w, h, rb, true, 2), w, h, rb, false, 2);
            var sh = new float[w * h]; for (int i = 0; i < sh.Length; i++) sh[i] = fine[i] - broad[i];
            var s2 = new List<float>(sh.Length / 5 + 1); for (int i = 0; i < sh.Length; i += 5) s2.Add(sh[i]);
            s2.Sort(); float lo = s2[(int)(s2.Count * 0.02)], hi = Math.Max(lo + 1f, s2[(int)(s2.Count * 0.98)]);
            float k = Math.Min(1f, shade);
            for (int i = 0; i < sh.Length; i++)
            {
                float s = Math.Max(0f, Math.Min(1f, (sh[i] - lo) / (hi - lo))), gv = Math.Max(0f, Math.Min(1f, sg[i] / top));
                float v = (1f - k) * (1f - gv) + k * s * (1f - 0.7f * gv);
                ob[i] = (byte)Math.Max(0, Math.Min(255, (int)(v * 255f + 0.5f)));
            }
            return ob;
        }
        /// <summary>Along x or y, radius r, wrapping (the textures repeat): op 1 = max (dilate), 0 = min (erode), 2 = mean (a box
        /// blur). Rows (or columns) in parallel; the wrap is a lookup, not a modulo per tap (~30 ms a texture before, 2026-10-12).</summary>
        static float[] MinMax(float[] a, int w, int h, int r, bool alongX, int op)
        {
            var o = new float[a.Length]; int len = alongX ? w : h, lines = alongX ? h : w;
            var wrap = new int[len + 2 * r]; for (int i = 0; i < wrap.Length; i++) wrap[i] = ((i - r) % len + len) % len;
            System.Threading.Tasks.Parallel.For(0, lines, line =>
            {
                var buf = new float[len];
                for (int i = 0; i < len; i++) buf[i] = alongX ? a[line * w + i] : a[i * w + line];
                for (int i = 0; i < len; i++)
                {
                    float m = op == 1 ? float.MinValue : (op == 0 ? float.MaxValue : 0f);
                    for (int k = 0; k <= 2 * r; k++)
                    {
                        float v = buf[wrap[i + k]];
                        if (op == 1) { if (v > m) m = v; } else if (op == 0) { if (v < m) m = v; } else m += v;
                    }
                    if (op == 2) m /= 2 * r + 1;
                    if (alongX) o[line * w + i] = m; else o[i * w + line] = m;
                }
            });
            return o;
        }        // A texture's companion maps on the card: one RGBA picture (R smoothness, G height, B glow) with its own mipmaps
        void MakeMat(Raster.Tex t, GTex g)
        {
            if (g.Mat != 0) { glDeleteTextures(1, new[] { g.Mat }); g.Mat = 0; g.Bytes -= g.MatB; TextureBytes -= g.MatB; g.MatB = 0; }
            g.MatSrc = t.MatPx; g.MatHas = 0;
            if (t.MatPx == null || t.MatW < 1 || t.MatH < 1 || t.MatPx.Length < t.MatW * t.MatH) return;
            var ids = new uint[1]; glGenTextures(1, ids); g.Mat = ids[0];
            glBindTexture(GL_TEXTURE_2D, g.Mat);
            glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, t.MatW, t.MatH, 0, GL_BGRA, GL_UNSIGNED_BYTE, t.MatPx);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_REPEAT);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR_MIPMAP_LINEAR);
            if (Anisotropy > 1f) glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, Anisotropy);
            glGenerateMipmap(GL_TEXTURE_2D);
            g.MatHas = t.MatHas; g.MatB = (long)t.MatW * t.MatH * 4 * 4 / 3; g.Bytes += g.MatB; TextureBytes += g.MatB;
            Check("uploading a texture's companion maps");
        }
        uint MakeSharpRelief(uint rgb, Raster.Tex t, ref long bytes) { return MakeSharpRelief(rgb, t, ref bytes, ReliefSharpK); }
        uint MakeSharpRelief(uint rgb, Raster.Tex t, ref long bytes, float k)
        {
            if (_pNorm2 == 0) _pNorm2 = Link(VS_CLEAR, FS_NORM2, "sharp relief maps");
            var ids = new uint[1]; glGenTextures(1, ids); uint nt = ids[0];
            bool has = t.Rgb != null && t.Rgb.Length > 0;
            int nw = has ? Math.Max(4, t.Rgb[0].W) : 4, nh = has ? Math.Max(4, t.Rgb[0].H) : 4;
            glBindTexture(GL_TEXTURE_2D, nt);
            glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_RGBA8, nw, nh, 0, GL_BGRA, GL_UNSIGNED_BYTE, IntPtr.Zero);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_REPEAT); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_REPEAT);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR_MIPMAP_LINEAR);
            int levels = 1 + (int)Math.Floor(Math.Log(Math.Max(nw, nh), 2));
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, levels - 1);
            if (Anisotropy > 1f) glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY, Anisotropy);
            glBindFramebuffer(GL_FRAMEBUFFER, _normFbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, nt, 0);
            glViewport(0, 0, nw, nh);
            glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST); glDisable(GL_BLEND); glDisable(GL_CULL_FACE); glColorMask(1, 1, 1, 1);
            glUseProgram(_pNorm2); glBindVertexArray(_eVao);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, rgb);
            glUniform1i(glGetUniformLocation(_pNorm2, "uAlb"), 0);
            glUniform2f(glGetUniformLocation(_pNorm2, "uTexel"), 1f / nw, 1f / nh);
            glUniform1f(glGetUniformLocation(_pNorm2, "uK"), has ? k : 0f);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glBindTexture(GL_TEXTURE_2D, nt); glGenerateMipmap(GL_TEXTURE_2D);
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glBindVertexArray(0);
            long b = (long)nw * nh * 4 * 4 / 3; bytes += b; SharpBytes += b; SharpMaps++;
            Check("making a sharp relief map");
            return nt;
        }
        uint _pNorm2;
        // Two layers, each a normal's x,y: FINEST = full size minus a 2-texel blur (bumps 1-2 texels across) in red/green,
        // FINE = 2- minus 8-texel blur in blue/alpha, so the shader can mix them (ReliefFine/ReliefMid) in play. (The first
        // cut used 1-4 and 4-32 texels: Josh found its bumps "too large"; the broad lumps are gone altogether now.)
        // Slope by Sobel over the texel's 3x3 neighbours (a central difference, smoothed across).
        const string FS_NORM2 = @"#version 400 core
uniform sampler2D uAlb; uniform vec2 uTexel; uniform float uK;
out vec4 oColor;
float lum(vec2 st, float lod) { return dot(textureLod(uAlb, st, lod).rgb, vec3(0.30, 0.59, 0.11)); }
vec2 h(vec2 st) { float l0 = lum(st, 0.0), l1 = lum(st, 1.0), l3 = lum(st, 3.0); return vec2(l0 - l1, l1 - l3); }
void main() {
    vec2 st = gl_FragCoord.xy * uTexel, dx = vec2(uTexel.x, 0.0), dy = vec2(0.0, uTexel.y);
    vec2 a = h(st - dx - dy), b = h(st - dy), c = h(st + dx - dy);
    vec2 d = h(st - dx),                    f = h(st + dx);
    vec2 g = h(st - dx + dy), i = h(st + dy), j = h(st + dx + dy);
    vec2 hx = ((c + 2.0 * f + j) - (a + 2.0 * d + g)) * 0.25;
    vec2 hy = ((g + 2.0 * i + j) - (a + 2.0 * b + c)) * 0.25;
    vec3 nf = normalize(vec3(-hx.x * uK, -hy.x * uK, 1.0)), nb = normalize(vec3(-hx.y * uK, -hy.y * uK, 1.0));
    oColor = vec4(nf.xy * 0.5 + 0.5, nb.xy * 0.5 + 0.5);
}";
        [DllImport("opengl32.dll")] static extern void glGetTexImage(uint target, int level, uint fmt, uint type, int[] px);
        /// <summary>Testing: how steep a texture's relief map came out -- the mean and the 90th
        /// percentile of the slope (|xy| of its normals), and its size. sharp: the sharp map's.</summary>
        public float[] ReliefStats(Raster.Tex t) { return ReliefStats(t, false); }
        public float[] ReliefStats(Raster.Tex t, bool sharp)
        {
            GTex g; if (!_tex.TryGetValue(t, out g)) return null;
            if (sharp ? g.NormHi == 0 : g.Norm == 0) return null;
            int aw = (t.Rgb != null && t.Rgb.Length > 0) ? t.Rgb[0].W : 1, ah = (t.Rgb != null && t.Rgb.Length > 0) ? t.Rgb[0].H : 1;
            int nw = sharp ? Math.Max(4, aw) : Math.Max(4, aw / 2), nh = sharp ? Math.Max(4, ah) : Math.Max(4, ah / 2);
            // (read back as BGRA: a two-channel map comes back with its x in red and y in green, as the first maps do)
            var px = new int[nw * nh]; glBindTexture(GL_TEXTURE_2D, sharp ? g.NormHi : g.Norm); glGetTexImage(GL_TEXTURE_2D, 0, GL_BGRA, GL_UNSIGNED_BYTE, px);
            var sl = new float[px.Length]; double sum = 0;
            for (int i = 0; i < px.Length; i++) { float x = ((px[i] >> 16) & 255) / 127.5f - 1f, y = ((px[i] >> 8) & 255) / 127.5f - 1f; sl[i] = (float)Math.Sqrt(x * x + y * y); sum += sl[i]; }
            Array.Sort(sl);
            return new float[] { (float)(sum / px.Length), sl[(int)(sl.Length * 0.9)], nw, nh };
        }
        /// <summary>Drop every texture from the card (they are uploaded again as rooms need them).</summary>
        public void ForgetTextures()
        {
            foreach (var g in _tex.Values) glDeleteTextures(6, new[] { g.Rgb, g.Mask, g.Norm, g.NormHi, g.Mat, g.Height });     // (0 is ignored)
            _tex.Clear(); TextureBytes = 0; SharpBytes = 0; SharpMaps = 0; HeightBytes = 0; HeightMaps = 0;
        }

        // ---- TEXTURE REPAIR (Josh, 2026-10-12, phase 3: "Fix badly stretched textures automatically. Find faces where the
        // original texture coordinates stretch or smear the art ... and give those faces the texture laid evenly from the world
        // instead" and "Hide the repeats. Big surfaces that repeat one texture many times (floors, pipes, rock walls) get it
        // mixed ... across the surface") ----------------------------------------------------------------------------------
        // Worked out once per room (SetRelay) from its geometry and its ORIGINAL art; Build swaps the coordinates in face by
        // face. A face is SMEARED when its texture coordinates lie in a line (the 1996 models mapped slabs, steps, doors and
        // frames from the front, so their sides streak one row of texels across), STRETCHED when one way runs over
        // RelayStretch times as many units per texel as the other. Repaired:
        //  1. FOLDED: beside an intact face of the same texture, a face takes that face's art mirrored over the edge they share
        //     -- the edge lines up exactly and the art stays in the part of the texture the modeller chose (ping-ponged inside
        //     it if the face is deeper than that part). Flat neighbours of a folded face carry on the same fold.
        //  2. EVENED: a run of stretched faces touching no intact face of the same texture (where a seam would show) has its
        //     coordinates scaled the stretched way about the run's middle to an even density, ping-ponged inside the part of
        //     the texture the run used unless it used the whole width.
        // Left alone: faces whose original footprint is one flat colour (a black plane sampling a dark corner is meant to be
        // black), garbage coordinates (-1.7e38 in the 1996 files), what moves, and a room's "repair": {"skip": [names]}.
        // MIXED: a surface whose coordinates run over RelayMixFrom tiles one way gets the texture twice, shifted by amounts that
        // change slowly across it, blended -- the repeating grid breaks up. Only along the ways it repeats (a pipe's length,
        // not round it); never on art with holes (chains, ropes) or folded faces. RelayOn: all of it (the watcher's F11).
        public bool RelayOn = true, MixOn = true, RelayDebug;
        public float RelayStretch = 4f, RelayMinArea = 20f, RelayFlatStd = 6f, RelayMixFrom = 1.5f, RelayMixScale = 0.6f, RelayBoxAniso = 1.8f, RelayBoxClosed = 0.75f;
        public int RelayFolded, RelayEvened, RelayFlat, RelayLeft, RelayBad, RelayMixed, RelayBoxed;
        public string RelayNote = "";
        int[] _relIdx; int _relN; long _relSig; float[] _relUv, _relRange; byte[] _relFlags; bool _relLive;
        public void ClearRelay() { _relIdx = null; _relN = 0; _relUv = null; _relRange = null; _relFlags = null; RelayNote = ""; RelayFolded = RelayEvened = RelayFlat = RelayLeft = RelayBad = RelayMixed = RelayBoxed = 0; }
        struct EKey : IEquatable<EKey>
        {
            public long A, B;
            public EKey(long a, long b) { if (a < b) { A = a; B = b; } else { A = b; B = a; } }
            public bool Equals(EKey o) { return A == o.A && B == o.B; }
            public override bool Equals(object o) { return o is EKey && Equals((EKey)o); }
            public override int GetHashCode() { return (A * 1000003L ^ B).GetHashCode(); }
        }
        static long PKey(float[] v, int i)
        {   // a corner's place to 1/20 unit (faces of different parts meet at equal positions, not equal vertex numbers)
            long x = (long)Math.Round(v[i * 3] * 20.0) & 0x1FFFFF, y = (long)Math.Round(v[i * 3 + 1] * 20.0) & 0x1FFFFF, z = (long)Math.Round(v[i * 3 + 2] * 20.0) & 0x1FFFFF;
            return (x << 42) | (y << 21) | z;
        }
        static long IdxSig(int[] idx)
        {   // (a cheap fingerprint of the triangle list: the same room's, or another's)
            long s = idx.Length; int step = Math.Max(1, idx.Length / 61);
            for (int i = 0; i < idx.Length; i += step) s = s * 31 + idx[i];
            return s;
        }
        /// <summary>The fold of a face over an edge: E0 + s*E (along it) + h*D (into the intact face), then that face's own
        /// mapping of (s, h) to texture coordinates; Lo/Size: the part of the texture it ping-pongs in.</summary>
        sealed class Fold { public double Ex, Ey, Ez, Ux, Uy, Uz, Dx, Dy, Dz, S0, H0, U0, V0, UdS, UdH, VdS, VdH, HMax; public float LoU, LoV, SizeU, SizeV; }
        /// <summary>How far face t reaches from the line through corners i0, i1 (its depth off that edge).</summary>
        static double DepthFrom(float[] vx, int[] idx, int t, int i0, int i1)
        {
            double ux = vx[i1 * 3] - vx[i0 * 3], uy = vx[i1 * 3 + 1] - vx[i0 * 3 + 1], uz = vx[i1 * 3 + 2] - vx[i0 * 3 + 2], ul = Math.Sqrt(ux * ux + uy * uy + uz * uz), m = 0;
            if (ul < 1e-9) return 0; ux /= ul; uy /= ul; uz /= ul;
            for (int k = 0; k < 3; k++)
            {
                int vi = idx[t * 3 + k]; double px = vx[vi * 3] - vx[i0 * 3], py = vx[vi * 3 + 1] - vx[i0 * 3 + 1], pz = vx[vi * 3 + 2] - vx[i0 * 3 + 2], s = px * ux + py * uy + pz * uz;
                double rx = px - s * ux, ry = py - s * uy, rz = pz - s * uz; m = Math.Max(m, Math.Sqrt(rx * rx + ry * ry + rz * rz));
            }
            return m;
        }
        /// <summary>How far face t reaches from fold f's edge.</summary>
        static double FoldDepth(Fold f, float[] vx, int[] idx, int t)
        {
            double m = 0;
            for (int k = 0; k < 3; k++)
            {
                int vi = idx[t * 3 + k]; double px = vx[vi * 3] - f.Ex, py = vx[vi * 3 + 1] - f.Ey, pz = vx[vi * 3 + 2] - f.Ez, s = px * f.Ux + py * f.Uy + pz * f.Uz;
                double rx = px - s * f.Ux, ry = py - s * f.Uy, rz = pz - s * f.Uz; m = Math.Max(m, Math.Sqrt(rx * rx + ry * ry + rz * rz));
            }
            return m;
        }
        /// <summary>Work out the room's texture repair (see above) from its triangles as Build will be given them. pal: the
        /// original palette (the art's own colours, for the flat-colour test); flipV as the draws; skip: texture names left as
        /// they are. Returns a line for the log.</summary>
        public string SetRelay(float[] vx, float[] uv, int[] idx, int[] triTex, Raster.Tex[] texes, byte[] pal, bool flipV, string[] skip)
        {
            ClearRelay();
            if (vx == null || uv == null || idx == null || triTex == null || texes == null) return RelayNote = "no room";
            var skipSet = new HashSet<string>(skip ?? new string[0], StringComparer.OrdinalIgnoreCase);
            int nT = Math.Min(idx.Length / 3, triTex.Length), nV = vx.Length / 3;
            var cls = new byte[nT];                   // 0 not ours, 1 intact, 2 smeared, 3 stretched, 4 garbage
            var area = new float[nT]; var nrm = new float[nT * 3]; var logAn = new float[nT]; var flat = new bool[nT]; var dens = new float[nT];     // (dens: an intact face's texels per unit)
            var pk = new long[nV]; for (int i = 0; i < nV; i++) pk[i] = PKey(vx, i);
            Func<int, Raster.Tex> TexOf = t => { int ti = triTex[t]; return ti >= 0 && ti < texes.Length ? texes[ti] : null; };
            for (int t = 0; t < nT; t++)
            {
                var tx = TexOf(t); if (tx == null || tx.Moves || tx.Ghost || tx.Idx == null || tx.Material == "water") continue;      // (water: the modern water's own look)
                if (tx.Leaf != null && skipSet.Contains(tx.Leaf)) continue;
                int a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
                if (a >= nV || b >= nV || c >= nV || a * 2 + 1 >= uv.Length || b * 2 + 1 >= uv.Length || c * 2 + 1 >= uv.Length) continue;
                double e1x = vx[b * 3] - vx[a * 3], e1y = vx[b * 3 + 1] - vx[a * 3 + 1], e1z = vx[b * 3 + 2] - vx[a * 3 + 2];
                double e2x = vx[c * 3] - vx[a * 3], e2y = vx[c * 3 + 1] - vx[a * 3 + 1], e2z = vx[c * 3 + 2] - vx[a * 3 + 2];
                double cx = e1y * e2z - e1z * e2y, cy = e1z * e2x - e1x * e2z, cz = e1x * e2y - e1y * e2x, cl = Math.Sqrt(cx * cx + cy * cy + cz * cz);
                if (cl < 2e-6) continue;
                area[t] = (float)(0.5 * cl); nrm[t * 3] = (float)(cx / cl); nrm[t * 3 + 1] = (float)(cy / cl); nrm[t * 3 + 2] = (float)(cz / cl);
                float ua = uv[a * 2], va = uv[a * 2 + 1], ub = uv[b * 2], vb = uv[b * 2 + 1], uc = uv[c * 2], vc = uv[c * 2 + 1];
                if (!(Math.Abs(ua) < 1e4f && Math.Abs(va) < 1e4f && Math.Abs(ub) < 1e4f && Math.Abs(vb) < 1e4f && Math.Abs(uc) < 1e4f && Math.Abs(vc) < 1e4f)) { cls[t] = 4; RelayBad++; continue; }
                double du1 = (ub - ua) * tx.W, dv1 = (vb - va) * tx.H, du2 = (uc - ua) * tx.W, dv2 = (vc - va) * tx.H, det = du1 * dv2 - du2 * dv1;
                if (Math.Abs(det) * 0.5 < 1e-3 * Math.Max(1.0, area[t])) { cls[t] = area[t] > RelayMinArea ? (byte)2 : (byte)0; }
                else
                {
                    double pux = (e1x * dv2 - e2x * dv1) / det, puy = (e1y * dv2 - e2y * dv1) / det, puz = (e1z * dv2 - e2z * dv1) / det;
                    double pvx = (e2x * du1 - e1x * du2) / det, pvy = (e2y * du1 - e1y * du2) / det, pvz = (e2z * du1 - e1z * du2) / det;
                    double lu = Math.Sqrt(pux * pux + puy * puy + puz * puz), lv = Math.Sqrt(pvx * pvx + pvy * pvy + pvz * pvz);
                    logAn[t] = (float)Math.Log(Math.Max(1e-9, lu) / Math.Max(1e-9, lv));      // > 0: stretched along u
                    cls[t] = Math.Abs(logAn[t]) > Math.Log(RelayStretch) && area[t] > RelayMinArea ? (byte)3 : (byte)1;
                    if (cls[t] == 1) dens[t] = (float)Math.Sqrt(Math.Abs(det) * 0.5 / area[t]);
                }
                if (cls[t] >= 2 && pal != null && pal.Length >= 768) flat[t] = FlatArt(tx, pal, flipV, ua, va, ub, vb, uc, vc);
                if (flat[t]) RelayFlat++;
            }
            // the edges, by place
            var edges = new Dictionary<EKey, List<int>>();
            for (int t = 0; t < nT; t++)
            {
                if (cls[t] == 0 || cls[t] == 4) continue;
                for (int e = 0; e < 3; e++)
                {
                    var k = new EKey(pk[idx[t * 3 + e]], pk[idx[t * 3 + (e + 1) % 3]]); List<int> l;
                    if (!edges.TryGetValue(k, out l)) { l = new List<int>(2); edges[k] = l; }
                    l.Add(t * 3 + e);
                }
            }
            Func<int, int, EKey> EdgeOf = (t, e) => new EKey(pk[idx[t * 3 + e]], pk[idx[t * 3 + (e + 1) % 3]]);
            Func<int, bool> Mendable = t => (cls[t] == 2 || cls[t] == 3) && !flat[t];
            var fold = new Fold[nT]; var newUv = new float[nT * 6]; var range = new float[nT * 4]; var flags = new byte[nT];
            // 1. FOLDS: each mendable face's best intact neighbour (the longest shared edge), longest first
            // a face flush with an intact face of its texture (sharing an edge, under ~25 degrees apart) would open a seam there if
            // it changed: those stay as they are
            Func<int, bool> Flush = t =>
            {
                var tx = TexOf(t);
                for (int e = 0; e < 3; e++)
                {
                    List<int> l; if (!edges.TryGetValue(EdgeOf(t, e), out l)) continue;
                    foreach (int ge in l)
                    {
                        int g = ge / 3; if (g == t || cls[g] != 1 || !ReferenceEquals(TexOf(g), tx)) continue;
                        if (Math.Abs(nrm[t * 3] * nrm[g * 3] + nrm[t * 3 + 1] * nrm[g * 3 + 1] + nrm[t * 3 + 2] * nrm[g * 3 + 2]) > 0.9) return true;
                    }
                }
                return false;
            };
            var cand = new List<double[]>();          // {shared edge's length, face, its edge, the intact face}
            for (int t = 0; t < nT; t++)
            {
                if (!Mendable(t) || Flush(t)) continue;
                var tx = TexOf(t); double best = 0; int bestE = -1, bestG = -1;
                for (int e = 0; e < 3; e++)
                {
                    List<int> l; if (!edges.TryGetValue(EdgeOf(t, e), out l)) continue;
                    int i0 = idx[t * 3 + e], i1 = idx[t * 3 + (e + 1) % 3];
                    double dx = vx[i1 * 3] - vx[i0 * 3], dy = vx[i1 * 3 + 1] - vx[i0 * 3 + 1], dz = vx[i1 * 3 + 2] - vx[i0 * 3 + 2], len = Math.Sqrt(dx * dx + dy * dy + dz * dz);
                    foreach (int ge in l)
                    {
                        int g = ge / 3; if (g == t || cls[g] != 1 || !ReferenceEquals(TexOf(g), tx)) continue;
                        // only round a corner (a flat run would show the mirror), and only a face no deeper than the one it
                        // borrows from (a step's riser off its tread, a slab's edge off its top, a door's side off its face)
                        double d = nrm[t * 3] * nrm[g * 3] + nrm[t * 3 + 1] * nrm[g * 3 + 1] + nrm[t * 3 + 2] * nrm[g * 3 + 2];
                        if (Math.Abs(d) > 0.9) continue;
                        if (DepthFrom(vx, idx, t, i0, i1) > DepthFrom(vx, idx, g, i0, i1) * 1.05 + 0.5) continue;
                        if (len > best) { best = len; bestE = e; bestG = g; }
                    }
                }
                if (bestG >= 0) cand.Add(new double[] { best, t, bestE, bestG });
            }
            cand.Sort((p, q) => q[0].CompareTo(p[0]));
            var queue = new Queue<int>();
            foreach (var cd in cand)
            {
                int t = (int)cd[1], e = (int)cd[2], g = (int)cd[3]; if (fold[t] != null) continue;
                var f = MakeFold(vx, uv, idx, pk, t, e, g); if (f == null) continue;
                fold[t] = f; queue.Enqueue(t);
                while (queue.Count > 0)
                {   // the flat neighbours of a folded face carry on its fold
                    int r = queue.Dequeue(); ApplyFold(fold[r], vx, idx, r, newUv, range, flags); RelayFolded++;
                    var tr = TexOf(r);
                    for (int e2 = 0; e2 < 3; e2++)
                    {
                        List<int> l; if (!edges.TryGetValue(EdgeOf(r, e2), out l)) continue;
                        foreach (int qe in l)
                        {
                            int q = qe / 3; if (q == r || fold[q] != null || !Mendable(q) || !ReferenceEquals(TexOf(q), tr)) continue;
                            double d = nrm[r * 3] * nrm[q * 3] + nrm[r * 3 + 1] * nrm[q * 3 + 1] + nrm[r * 3 + 2] * nrm[q * 3 + 2];
                            if (Math.Abs(d) < 0.95 || FoldDepth(fold[r], vx, idx, q) > fold[r].HMax * 1.05 + 0.5 || Flush(q)) continue;
                            fold[q] = fold[r]; queue.Enqueue(q);
                        }
                    }
                }
            }
            // 2. EVENED: runs of stretched faces (connected, same texture) touching no intact face of their texture
            var seen = new bool[nT]; var run = new List<int>();
            for (int t0 = 0; t0 < nT; t0++)
            {
                if (seen[t0] || fold[t0] != null || cls[t0] != 3 || flat[t0]) continue;
                run.Clear(); queue.Enqueue(t0); seen[t0] = true; bool touches = false; var tx = TexOf(t0);
                while (queue.Count > 0)
                {
                    int r = queue.Dequeue(); run.Add(r);
                    for (int e2 = 0; e2 < 3; e2++)
                    {
                        List<int> l; if (!edges.TryGetValue(EdgeOf(r, e2), out l)) continue;
                        foreach (int qe in l)
                        {
                            int q = qe / 3; if (q == r || !ReferenceEquals(TexOf(q), tx)) continue;
                            if (cls[q] == 1 && Math.Abs(nrm[r * 3] * nrm[q * 3] + nrm[r * 3 + 1] * nrm[q * 3 + 1] + nrm[r * 3 + 2] * nrm[q * 3 + 2]) > 0.9) touches = true;     // (round a corner -- a pipe's end -- no seam shows)
                            if (!seen[q] && fold[q] == null && cls[q] == 3 && !flat[q]) { seen[q] = true; queue.Enqueue(q); }
                        }
                    }
                }
                if (touches) continue;
                double sa = 0, sl = 0, cu = 0, cv = 0, u0 = 1e9, u1 = -1e9, v0 = 1e9, v1 = -1e9;
                foreach (int r in run)
                {
                    sa += area[r]; sl += area[r] * logAn[r];
                    for (int k = 0; k < 3; k++) { int vi = idx[r * 3 + k]; double u = uv[vi * 2], v = uv[vi * 2 + 1]; cu += area[r] * u / 3; cv += area[r] * v / 3; u0 = Math.Min(u0, u); u1 = Math.Max(u1, u); v0 = Math.Min(v0, v); v1 = Math.Max(v1, v); }
                }
                double la = sl / Math.Max(1e-9, sa); cu /= Math.Max(1e-9, sa); cv /= Math.Max(1e-9, sa);
                double ku = la > 0 ? Math.Min(64, Math.Exp(la)) : 1, kv = la < 0 ? Math.Min(64, Math.Exp(-la)) : 1;
                bool pu = ku > 1 && u1 - u0 > 1e-4 && u1 - u0 < 0.98, pv = kv > 1 && v1 - v0 > 1e-4 && v1 - v0 < 0.98;
                foreach (int r in run)
                {
                    for (int k = 0; k < 3; k++) { int vi = idx[r * 3 + k]; newUv[r * 6 + k * 2] = (float)(cu + ku * (uv[vi * 2] - cu)); newUv[r * 6 + k * 2 + 1] = (float)(cv + kv * (uv[vi * 2 + 1] - cv)); }
                    range[r * 4] = (float)u0; range[r * 4 + 1] = (float)v0; range[r * 4 + 2] = (float)(u1 - u0); range[r * 4 + 3] = (float)(v1 - v0);
                    flags[r] = (byte)(16 | 32 | (pu ? 1 : 0) | (pv ? 2 : 0)); RelayEvened++;
                }
            }
            // 3. BOXED: a solid object of one texture (its faces joined by edges, RelayBoxClosed) stretched on the whole (RelayBoxAniso)
            //    -- a low-poly rock whose texture was projected from one side (Josh, 2026-10-12, CORICORI's save-point rock: "one of
            //    the more obvious smearing textures"): the WHOLE object re-laid from the world, each face along its main axis (box
            //    mapping) at the object's own texel density (its intact faces', else the room's), its middle on the middle of the
            //    texture coordinates it had, ping-ponged inside the part of the texture it used. Never on art with holes.
            var keyed = new Dictionary<Raster.Tex, bool>();
            Func<Raster.Tex, bool> Keyed = tk => { bool k0; if (!keyed.TryGetValue(tk, out k0)) { var src = tk.IdxOrig ?? tk.Idx; int z = 0; for (int i = 0; i < src.Length; i++) if (src[i] == 0) z++; k0 = z > src.Length / 200; keyed[tk] = k0; } return k0; };
            double roomDens = WMedian(dens, area, null, nT);
            var comp = new int[nT]; int stamp = 0;
            Array.Clear(seen, 0, nT);
            for (int t0 = 0; t0 < nT; t0++)
            {
                if (seen[t0] || cls[t0] < 1 || cls[t0] > 3) continue;
                var tx = TexOf(t0);
                run.Clear(); queue.Enqueue(t0); seen[t0] = true;
                while (queue.Count > 0)
                {
                    int r = queue.Dequeue(); run.Add(r);
                    for (int e2 = 0; e2 < 3; e2++)
                    {
                        List<int> l; if (!edges.TryGetValue(EdgeOf(r, e2), out l)) continue;
                        foreach (int qe in l) { int q = qe / 3; if (!seen[q] && cls[q] >= 1 && cls[q] <= 3 && ReferenceEquals(TexOf(q), tx)) { seen[q] = true; queue.Enqueue(q); } }
                    }
                }
                // (stretched ON THE WHOLE -- its faces' area-weighted anisotropy, a smear counting as 8x -- with at least two badly
                // stretched or smeared: the save-point rock's side is only 2-3x per face, but the sharp new art streaks at that)
                double tot = 0, la = 0; int nBad = 0;
                foreach (int r in run) { tot += area[r]; la += area[r] * (cls[r] == 2 ? Math.Log(8) : Math.Abs(logAn[r])); if (Mendable(r)) nBad++; }
                if (nBad < 2 || la < Math.Log(RelayBoxAniso) * tot || Keyed(tx)) continue;
                // (and only a SOLID object -- most of its edges shared by two of its own faces: a rock, a block. An open sheet --
                // a cave wall -- keeps its own laying: MINEMAZE's walls carry a torch's glow painted where the torch is)
                stamp++; foreach (int r in run) comp[r] = stamp;
                int eIn = 0, eAll = 0;
                foreach (int r in run)
                    for (int e2 = 0; e2 < 3; e2++)
                    {
                        eAll++; List<int> l; if (!edges.TryGetValue(EdgeOf(r, e2), out l)) continue;
                        foreach (int qe in l) if (qe / 3 != r && comp[qe / 3] == stamp) { eIn++; break; }
                    }
                if (eIn < RelayBoxClosed * eAll) continue;
                double d = WMedian(dens, area, run, 0); if (!(d > 0)) d = roomDens; if (!(d > 0)) continue;
                double sa = 0, ox = 0, oy = 0, oz = 0, cu = 0, cv = 0, u0 = 1e9, u1 = -1e9, v0 = 1e9, v1 = -1e9;
                foreach (int r in run)
                    for (int k = 0; k < 3; k++)
                    {
                        int vi = idx[r * 3 + k]; double w = area[r] / 3.0, u = uv[vi * 2], v = uv[vi * 2 + 1];
                        sa += w; ox += w * vx[vi * 3]; oy += w * vx[vi * 3 + 1]; oz += w * vx[vi * 3 + 2]; cu += w * u; cv += w * v;
                        u0 = Math.Min(u0, u); u1 = Math.Max(u1, u); v0 = Math.Min(v0, v); v1 = Math.Max(v1, v);
                    }
                ox /= sa; oy /= sa; oz /= sa; cu /= sa; cv /= sa;
                double ku = d / tx.W, kv = (flipV ? 1 : -1) * d / tx.H;      // (the art's top up the world)
                bool pu = u1 - u0 > 1e-4 && u1 - u0 < 0.98, pv = v1 - v0 > 1e-4 && v1 - v0 < 0.98;
                foreach (int r in run)
                {
                    // (a PICTURE face -- laid evenly over a quarter or more of the texture each way, a chest's front -- keeps its own
                    // laying. A rock's faces each sample a small patch: all of them are re-laid, or its streaky patches stay)
                    if (cls[r] == 1 && Math.Abs(logAn[r]) <= Math.Log(1.5))
                    {
                        float fu0 = Math.Min(uv[idx[r * 3] * 2], Math.Min(uv[idx[r * 3 + 1] * 2], uv[idx[r * 3 + 2] * 2])), fu1 = Math.Max(uv[idx[r * 3] * 2], Math.Max(uv[idx[r * 3 + 1] * 2], uv[idx[r * 3 + 2] * 2]));
                        float fv0 = Math.Min(uv[idx[r * 3] * 2 + 1], Math.Min(uv[idx[r * 3 + 1] * 2 + 1], uv[idx[r * 3 + 2] * 2 + 1])), fv1 = Math.Max(uv[idx[r * 3] * 2 + 1], Math.Max(uv[idx[r * 3 + 1] * 2 + 1], uv[idx[r * 3 + 2] * 2 + 1]));
                        if (fu1 - fu0 >= 0.25f && fv1 - fv0 >= 0.25f) continue;
                    }
                    double ax = Math.Abs(nrm[r * 3]), ay = Math.Abs(nrm[r * 3 + 1]), az = Math.Abs(nrm[r * 3 + 2]);
                    for (int k = 0; k < 3; k++)
                    {
                        int vi = idx[r * 3 + k]; double px = vx[vi * 3] - ox, py = vx[vi * 3 + 1] - oy, pz = vx[vi * 3 + 2] - oz, s, h;
                        if (ay >= ax && ay >= az) { s = px; h = pz; }                                     // (a top or underside: laid flat)
                        else if (ax >= az) { s = pz * Math.Sign(nrm[r * 3]); h = py; }                     // (a side facing along x)
                        else { s = -px * Math.Sign(nrm[r * 3 + 2]); h = py; }                              // (a side facing along z)
                        newUv[r * 6 + k * 2] = (float)(cu + s * ku); newUv[r * 6 + k * 2 + 1] = (float)(cv + h * kv);
                    }
                    range[r * 4] = (float)u0; range[r * 4 + 1] = (float)v0; range[r * 4 + 2] = (float)(u1 - u0); range[r * 4 + 3] = (float)(v1 - v0);
                    flags[r] = (byte)(16 | 64 | (pu ? 1 : 0) | (pv ? 2 : 0)); fold[r] = null; RelayBoxed++;
                }
            }
            for (int t = 0; t < nT; t++) if (Mendable(t) && (flags[t] & 16) == 0) RelayLeft++;
            // 3. MIXED: surfaces (connected, same texture, intact or evened without a ping-pong that way) whose coordinates run
            //    over RelayMixFrom tiles one way, on art without holes
            var tiles = new Dictionary<Raster.Tex, bool[]>();
            Array.Clear(seen, 0, nT);
            Func<int, int, float> U = (t, k) => (flags[t] & 16) != 0 ? newUv[t * 6 + k * 2] : uv[idx[t * 3 + k] * 2];
            Func<int, int, float> V = (t, k) => (flags[t] & 16) != 0 ? newUv[t * 6 + k * 2 + 1] : uv[idx[t * 3 + k] * 2 + 1];
            Func<int, bool> Mixable = t => (cls[t] == 1 || cls[t] == 3) && fold[t] == null && (flags[t] & 64) == 0;
            for (int t0 = 0; t0 < nT; t0++)
            {
                if (seen[t0] || !Mixable(t0)) continue;
                var tx = TexOf(t0); bool k0;
                k0 = Keyed(tx);
                run.Clear(); queue.Enqueue(t0); seen[t0] = true;
                double u0 = 1e9, u1 = -1e9, v0 = 1e9, v1 = -1e9;
                while (queue.Count > 0)
                {
                    int r = queue.Dequeue(); run.Add(r);
                    for (int k = 0; k < 3; k++) { u0 = Math.Min(u0, U(r, k)); u1 = Math.Max(u1, U(r, k)); v0 = Math.Min(v0, V(r, k)); v1 = Math.Max(v1, V(r, k)); }
                    for (int e2 = 0; e2 < 3; e2++)
                    {
                        List<int> l; if (!edges.TryGetValue(EdgeOf(r, e2), out l)) continue;
                        foreach (int qe in l) { int q = qe / 3; if (!seen[q] && Mixable(q) && ReferenceEquals(TexOf(q), tx)) { seen[q] = true; queue.Enqueue(q); } }
                    }
                }
                if (k0) continue;
                // (only along a way the art tiles cleanly: shifting a texture with dark or unmatched edges scatters its seam
                // about the surface instead of hiding it -- Test-TextureTiling.ps1 lists those for the art)
                bool[] clean; if (!tiles.TryGetValue(tx, out clean)) { clean = TilesClean(tx, pal); tiles[tx] = clean; }
                bool mu = u1 - u0 >= RelayMixFrom && clean[0], mv = v1 - v0 >= RelayMixFrom && clean[1];
                if (!mu && !mv) continue;
                foreach (int r in run)
                {
                    bool ru = mu && (flags[r] & 1) == 0, rv = mv && (flags[r] & 2) == 0;
                    if (ru || rv) { flags[r] |= (byte)((ru ? 4 : 0) | (rv ? 8 : 0)); RelayMixed++; }
                }
            }
            _relIdx = idx; _relN = nT; _relSig = IdxSig(idx); _relUv = newUv; _relRange = range; _relFlags = flags;
            RelayNote = string.Format("{0} faces folded over an edge, {1} evened, {6} in objects re-laid whole, {2} mixed against repeats; left as they were: {3} flat colour, {4} that would seam, {5} with garbage coordinates", RelayFolded, RelayEvened, RelayMixed, RelayFlat, RelayLeft, RelayBad, RelayBoxed);
            return RelayNote;
        }
        /// <summary>Whether the original art tiles cleanly along u (its left and right edges) and along v (top and bottom): neither
        /// edge band (6% deep) much darker than its middle, and the two edges meeting (their brightness along the edge, smoothed
        /// over 5 texels, within 35% of the middle's). As Test-TextureTiling.ps1's DARK EDGES / SEAM.</summary>
        static bool[] TilesClean(Raster.Tex tx, byte[] pal)
        {
            if (pal == null || pal.Length < 768) return new[] { true, true };
            var src = tx.IdxOrig ?? tx.Idx; int W = tx.W, H = tx.H;
            Func<int, int, double> L = (x, y) => { int p = src[y * W + x] * 3; return 0.30 * pal[p] + 0.59 * pal[p + 1] + 0.11 * pal[p + 2]; };
            Func<int, int, int, int, double> Mean = (x0, y0, x1, y1) => { double s = 0; int n = 0; for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) { s += L(x, y); n++; } return n > 0 ? s / n : 0; };
            int bx = Math.Max(1, W * 6 / 100), by = Math.Max(1, H * 6 / 100);
            double mid = Mean(W / 4, H / 4, W * 3 / 4, H * 3 / 4), m = Math.Max(mid, 1);
            if (mid < 12) return new[] { true, true };          // (art this dark shows no seam)
            double top = Mean(0, 0, W, by) / m, bot = Mean(0, H - by, W, H) / m, left = Mean(0, 0, bx, H) / m, right = Mean(W - bx, 0, W, H) / m;
            double tb = 0, lr = 0;
            for (int x = 0; x < W; x++) { double a = 0, b = 0; for (int k = -2; k <= 2; k++) { int xx = ((x + k) % W + W) % W; a += L(xx, 0); b += L(xx, H - 1); } tb += Math.Abs(a - b) / 5; }
            for (int y = 0; y < H; y++) { double a = 0, b = 0; for (int k = -2; k <= 2; k++) { int yy = ((y + k) % H + H) % H; a += L(0, yy); b += L(W - 1, yy); } lr += Math.Abs(a - b) / 5; }
            tb /= W * m; lr /= H * m;
            return new[] { left >= 0.6 && right >= 0.6 && lr <= 0.35, top >= 0.6 && bot >= 0.6 && tb <= 0.35 };
        }
        /// <summary>The area-weighted median of v (its positive values) over the faces in `list` (null: the first n).</summary>
        static double WMedian(float[] v, float[] w, List<int> list, int n)
        {
            var ks = new List<KeyValuePair<float, float>>(); double tw = 0;
            if (list != null) { foreach (int i in list) if (v[i] > 0) { ks.Add(new KeyValuePair<float, float>(v[i], w[i])); tw += w[i]; } }
            else for (int i = 0; i < n; i++) if (v[i] > 0) { ks.Add(new KeyValuePair<float, float>(v[i], w[i])); tw += w[i]; }
            if (ks.Count == 0) return 0;
            ks.Sort((a, b) => a.Key.CompareTo(b.Key)); double acc = 0;
            foreach (var kv in ks) { acc += kv.Value; if (acc >= tw * 0.5) return kv.Key; }
            return ks[ks.Count - 1].Key;
        }        /// <summary>The original art under a face's three texture coordinates is one flat colour (or black, or all holes).</summary>
        bool FlatArt(Raster.Tex tx, byte[] pal, bool flipV, float ua, float va, float ub, float vb, float uc, float vc)
        {
            var src = tx.IdxOrig ?? tx.Idx; int W = tx.W, H = tx.H, n = 0; double s = 0, s2 = 0;
            for (int i = 0; i <= 4; i++)
                for (int j = 0; i + j <= 4; j++)
                {
                    float a = i / 4f, b = j / 4f, c = 1f - a - b;
                    double u = a * ua + b * ub + c * uc, v = a * va + b * vb + c * vc; if (flipV) v = 1.0 - v;
                    int x = Math.Min(W - 1, Math.Max(0, (int)Math.Floor((u - Math.Floor(u)) * W))), y = Math.Min(H - 1, Math.Max(0, (int)Math.Floor((v - Math.Floor(v)) * H)));
                    int p = src[y * W + x]; if (p == 0) continue;
                    double L = 0.30 * pal[p * 3] + 0.59 * pal[p * 3 + 1] + 0.11 * pal[p * 3 + 2]; s += L; s2 += L * L; n++;
                }
            if (n < 3) return true;
            double m = s / n, sd = Math.Sqrt(Math.Max(0, s2 / n - m * m));
            return sd < RelayFlatStd || m < 6;
        }
        /// <summary>Face t's edge e lies on intact face g: g's mapping, read mirrored back across that edge.</summary>
        static Fold MakeFold(float[] vx, float[] uv, int[] idx, long[] pk, int t, int e, int g)
        {
            int i0 = idx[t * 3 + e], i1 = idx[t * 3 + (e + 1) % 3];
            double ex = vx[i0 * 3], ey = vx[i0 * 3 + 1], ez = vx[i0 * 3 + 2];
            double ux = vx[i1 * 3] - ex, uy = vx[i1 * 3 + 1] - ey, uz = vx[i1 * 3 + 2] - ez, ul = Math.Sqrt(ux * ux + uy * uy + uz * uz);
            if (ul < 1e-6) return null; ux /= ul; uy /= ul; uz /= ul;
            // g's corner off the edge, and the way into g from the edge
            int third = -1;
            for (int k = 0; k < 3; k++) { int gi = idx[g * 3 + k]; if (pk[gi] != pk[i0] && pk[gi] != pk[i1]) third = gi; }
            if (third < 0) return null;
            double wx = vx[third * 3] - ex, wy = vx[third * 3 + 1] - ey, wz = vx[third * 3 + 2] - ez, ws = wx * ux + wy * uy + wz * uz;
            double dx = wx - ws * ux, dy = wy - ws * uy, dz = wz - ws * uz, dl = Math.Sqrt(dx * dx + dy * dy + dz * dz);
            if (dl < 1e-6) return null; dx /= dl; dy /= dl; dz /= dl;
            // g's (s, h) -> (u, v), from its three corners
            var s = new double[3]; var h = new double[3]; var tu = new double[3]; var tv = new double[3];
            float lu0 = float.MaxValue, lv0 = float.MaxValue, lu1 = float.MinValue, lv1 = float.MinValue;
            for (int k = 0; k < 3; k++)
            {
                int gi = idx[g * 3 + k]; double px = vx[gi * 3] - ex, py = vx[gi * 3 + 1] - ey, pz = vx[gi * 3 + 2] - ez;
                s[k] = px * ux + py * uy + pz * uz; h[k] = px * dx + py * dy + pz * dz; tu[k] = uv[gi * 2]; tv[k] = uv[gi * 2 + 1];
                lu0 = Math.Min(lu0, uv[gi * 2]); lu1 = Math.Max(lu1, uv[gi * 2]); lv0 = Math.Min(lv0, uv[gi * 2 + 1]); lv1 = Math.Max(lv1, uv[gi * 2 + 1]);
            }
            double s1 = s[1] - s[0], h1 = h[1] - h[0], s2 = s[2] - s[0], h2 = h[2] - h[0], det = s1 * h2 - s2 * h1;
            if (Math.Abs(det) < 1e-9) return null;
            var f = new Fold { Ex = ex, Ey = ey, Ez = ez, Ux = ux, Uy = uy, Uz = uz, Dx = dx, Dy = dy, Dz = dz, S0 = s[0], H0 = h[0], U0 = tu[0], V0 = tv[0], HMax = Math.Max(h[0], Math.Max(h[1], h[2])) };
            f.UdS = ((tu[1] - tu[0]) * h2 - (tu[2] - tu[0]) * h1) / det; f.UdH = ((tu[2] - tu[0]) * s1 - (tu[1] - tu[0]) * s2) / det;
            f.VdS = ((tv[1] - tv[0]) * h2 - (tv[2] - tv[0]) * h1) / det; f.VdH = ((tv[2] - tv[0]) * s1 - (tv[1] - tv[0]) * s2) / det;
            f.LoU = lu0; f.LoV = lv0; f.SizeU = lu1 - lu0; f.SizeV = lv1 - lv0;
            return f;
        }
        /// <summary>Face t's corners through fold f: along the edge as they are, their distance from it laid into the intact face.</summary>
        static void ApplyFold(Fold f, float[] vx, int[] idx, int t, float[] newUv, float[] range, byte[] flags)
        {
            for (int k = 0; k < 3; k++)
            {
                int vi = idx[t * 3 + k]; double px = vx[vi * 3] - f.Ex, py = vx[vi * 3 + 1] - f.Ey, pz = vx[vi * 3 + 2] - f.Ez;
                double s = px * f.Ux + py * f.Uy + pz * f.Uz, rx = px - s * f.Ux, ry = py - s * f.Uy, rz = pz - s * f.Uz, h = Math.Sqrt(rx * rx + ry * ry + rz * rz);
                newUv[t * 6 + k * 2] = (float)(f.U0 + f.UdS * (s - f.S0) + f.UdH * (h - f.H0));
                newUv[t * 6 + k * 2 + 1] = (float)(f.V0 + f.VdS * (s - f.S0) + f.VdH * (h - f.H0));
            }
            range[t * 4] = f.LoU; range[t * 4 + 1] = f.LoV; range[t * 4 + 2] = f.SizeU; range[t * 4 + 3] = f.SizeV;
            flags[t] = (byte)(16 | (f.SizeU > 1e-4f ? 1 : 0) | (f.SizeV > 1e-4f ? 2 : 0));
        }

        // ---- vertex sets -----------------------------------------------------------------------
        const int VSTRIDE = 15;                     // floats per vertex: x y z, u v, facing nx ny nz, lod, ping-pong lo u v size u v, repair flags
        class VSet { public uint Vao, Vbo; public float[] Verts = new float[0]; public int[] Start = new int[1], Count = new int[0], Fill = new int[0]; public int Kept, Nt; }
        VSet _main, _mirror, _cast;
        // THE PLAYER'S SHADOW BODY (ScanWire.BodyTris): triangles in world space that cast into the PLACED LIGHTS' shadow
        // views only -- never drawn, never in the helmet lamp's views (it is at the eye: the body would shadow what it lights).
        float[] _castTris; int _castN;
        /// <summary>For the next Draw: shadow-only triangles (9 floats each, world space). Used up by it.</summary>
        public void SetCasters(float[] tris, int n) { _castTris = tris; _castN = (tris == null) ? 0 : Math.Max(0, Math.Min(n, tris.Length / 9)); }
        public int LastCasters;
        void UploadCasters()
        {
            if (_cast == null) _cast = NewSet();
            int n = _castN; if (_cast.Verts.Length < n * 3 * VSTRIDE) _cast.Verts = new float[n * 3 * VSTRIDE];
            var v = _cast.Verts;
            for (int i = 0; i < n * 3; i++) { int o = i * VSTRIDE; v[o] = _castTris[i * 3]; v[o + 1] = _castTris[i * 3 + 1]; v[o + 2] = _castTris[i * 3 + 2]; for (int k = 3; k < VSTRIDE; k++) v[o + k] = 0; }
            glBindVertexArray(_cast.Vao); glBindBuffer(GL_ARRAY_BUFFER, _cast.Vbo);
            glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)Math.Max(1, n) * 3 * VSTRIDE * 4), v, GL_STREAM_DRAW);
        }
        VSet NewSet()
        {
            var s = new VSet(); var ids = new uint[1];
            glGenVertexArrays(1, ids); s.Vao = ids[0]; glBindVertexArray(s.Vao);
            glGenBuffers(1, ids); s.Vbo = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, s.Vbo);
            glEnableVertexAttribArray(0); glVertexAttribPointer(0, 3, GL_FLOAT, 0, VSTRIDE * 4, IntPtr.Zero);
            glEnableVertexAttribArray(1); glVertexAttribPointer(1, 2, GL_FLOAT, 0, VSTRIDE * 4, new IntPtr(12));
            glEnableVertexAttribArray(2); glVertexAttribPointer(2, 4, GL_FLOAT, 0, VSTRIDE * 4, new IntPtr(20));
            glEnableVertexAttribArray(3); glVertexAttribPointer(3, 1, GL_FLOAT, 0, VSTRIDE * 4, new IntPtr(36));
            glEnableVertexAttribArray(4); glVertexAttribPointer(4, 4, GL_FLOAT, 0, VSTRIDE * 4, new IntPtr(40));
            glEnableVertexAttribArray(5); glVertexAttribPointer(5, 1, GL_FLOAT, 0, VSTRIDE * 4, new IntPtr(56));
            return s;
        }
        /// <summary>Triangles grouped by texture, each corner carrying Raster's per-triangle numbers
        /// for the camera `V`, sent to the card.</summary>
        void Build(VSet s, float[] vx, float[] uv, int[] idx, int[] triTex, Raster.Tex[] texes, float[] V)
        {
            int nTri = idx.Length / 3, nt = texes.Length;
            if (s.Start.Length < nt + 1) { s.Start = new int[nt + 1]; s.Count = new int[nt]; s.Fill = new int[nt]; }
            Array.Clear(s.Count, 0, nt);
            int kept = 0;
            for (int t = 0; t < nTri; t++) { int ti = triTex[t]; if (ti < 0 || ti >= nt || texes[ti] == null) continue; s.Count[ti]++; kept++; }
            s.Start[0] = 0; for (int i = 0; i < nt; i++) s.Start[i + 1] = s.Start[i] + s.Count[i];
            Array.Copy(s.Start, s.Fill, nt);
            if (s.Verts.Length < kept * 3 * VSTRIDE) s.Verts = new float[kept * 3 * VSTRIDE];
            float[] verts = s.Verts;
            float log2Fpx = (float)Math.Log(FocalPx, 2.0), bias = MipBias;
            for (int t = 0; t < nTri; t++)
            {
                int ti = triTex[t]; if (ti < 0 || ti >= nt || texes[ti] == null) continue;
                int a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
                // the corners in view space, as Raster.ToView
                float ax = vx[a * 3], ay = vx[a * 3 + 1], az = vx[a * 3 + 2], bx = vx[b * 3], by = vx[b * 3 + 1], bz = vx[b * 3 + 2], cx = vx[c * 3], cy = vx[c * 3 + 1], cz = vx[c * 3 + 2];
                float pax = ax * V[0] + ay * V[4] + az * V[8] + V[12], pay = ax * V[1] + ay * V[5] + az * V[9] + V[13], paz = ax * V[2] + ay * V[6] + az * V[10] + V[14];
                float pbx = bx * V[0] + by * V[4] + bz * V[8] + V[12], pby = bx * V[1] + by * V[5] + bz * V[9] + V[13], pbz = bx * V[2] + by * V[6] + bz * V[10] + V[14];
                float pcx = cx * V[0] + cy * V[4] + cz * V[8] + V[12], pcy = cx * V[1] + cy * V[5] + cz * V[9] + V[13], pcz = cx * V[2] + cy * V[6] + cz * V[10] + V[14];
                // Raster's per-triangle numbers, its own arithmetic (DrawFastCore, "prepare")
                float ux = pbx - pax, uy = pby - pay, uz = pbz - paz, wx = pcx - pax, wy = pcy - pay, wz = pcz - paz;
                float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx;
                float sx = pax + pbx + pcx, sy = pay + pby + pcy, sz = paz + pbz + pcz;
                float den = (float)Math.Sqrt((nx * nx + ny * ny + nz * nz) * (sx * sx + sy * sy + sz * sz));
                float f = den > 1e-12f ? Math.Abs(nx * sx + ny * sy + nz * sz) / den : 1f;
                float facing = 0.35f + 0.65f * f;
                float nl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz), tnx = 0f, tny = 0f, tnz = 1f;
                if (nl > 1e-12f) { tnx = nx / nl; tny = ny / nl; tnz = nz / nl; }
                Raster.Tex tx = texes[ti];
                // TEXTURE REPAIR (SetRelay): this face's own coordinates if it was re-laid, its ping-pong and mix flags
                int rf = _relLive && t < _relN ? _relFlags[t] : 0;
                float ua, va, ub, vb, uc, vc;
                if ((rf & 16) != 0) { int r6 = t * 6; ua = _relUv[r6]; va = _relUv[r6 + 1]; ub = _relUv[r6 + 2]; vb = _relUv[r6 + 3]; uc = _relUv[r6 + 4]; vc = _relUv[r6 + 5]; }
                else { ua = uv[a * 2]; va = uv[a * 2 + 1]; ub = uv[b * 2]; vb = uv[b * 2 + 1]; uc = uv[c * 2]; vc = uv[c * 2 + 1]; }
                float rLoU = 0f, rLoV = 0f, rSzU = 0f, rSzV = 0f;
                if ((rf & 3) != 0) { int r4 = t * 4; rLoU = _relRange[r4]; rLoV = _relRange[r4 + 1]; rSzU = _relRange[r4 + 2]; rSzV = _relRange[r4 + 3]; }
                float tw0 = tx.Rgb != null ? tx.Rgb[0].W : tx.W, th0 = tx.Rgb != null ? tx.Rgb[0].H : tx.H;
                float du1 = (ub - ua) * tw0, dv1 = (vb - va) * th0, du2 = (uc - ua) * tw0, dv2 = (vc - va) * th0;
                float texArea = Math.Abs(du1 * dv2 - du2 * dv1), worldArea = nl, lod = -100f;
                if (texArea > 1e-6f && worldArea > 1e-6f)
                {
                    float fcl = f < 0.06f ? 0.06f : f;
                    lod = 0.5f * (float)Math.Log(texArea / worldArea, 2.0) - log2Fpx - 0.5f * (float)Math.Log(fcl, 2.0) + bias;
                }
                int o = s.Fill[ti]++ * 3 * VSTRIDE;
                for (int k = 0; k < 3; k++)
                {
                    int vi = k == 0 ? a : (k == 1 ? b : c), q = o + k * VSTRIDE;
                    verts[q] = vx[vi * 3]; verts[q + 1] = vx[vi * 3 + 1]; verts[q + 2] = vx[vi * 3 + 2];
                    verts[q + 3] = k == 0 ? ua : (k == 1 ? ub : uc); verts[q + 4] = k == 0 ? va : (k == 1 ? vb : vc);
                    verts[q + 5] = facing; verts[q + 6] = tnx; verts[q + 7] = tny; verts[q + 8] = tnz; verts[q + 9] = lod;
                    verts[q + 10] = rLoU; verts[q + 11] = rLoV; verts[q + 12] = rSzU; verts[q + 13] = rSzV; verts[q + 14] = rf;
                }
            }
            s.Kept = kept; s.Nt = nt;
            glBindVertexArray(s.Vao);
            glBindBuffer(GL_ARRAY_BUFFER, s.Vbo);
            glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)Math.Max(1, kept) * 3 * VSTRIDE * 4), verts, GL_STREAM_DRAW);
        }
        /// <summary>Every texture group of a set, with its colour on unit 0 and its holes on unit 1.</summary>
        /// <summary>Characters (Tex.Moves) drawn double-sided.</summary>
        public bool TwoSidedMoves = false;
        bool _culling;
        int DrawSet(VSet s, Raster.Tex[] texes, bool colour)
        {
            glBindVertexArray(s.Vao);
            int batches = 0;
            for (int i = 0; i < s.Nt; i++)
            {
                if (s.Count[i] == 0) continue;
                if (GhostOn && texes[i].Ghost) continue;          // (a ghost: drawn as smoke by DrawGhost, casting nothing, in no reflection)
                if (!colour && texes[i].NoCast) continue;        // (the shadow views: what casts no shadow is left out)
                if (!colour) { bool prop = _pTex != null && Array.IndexOf(_pTex, texes[i]) >= 0; glUniform4f(glGetUniformLocation(_pDepth, "uSkip"), _skip[0], _skip[1], _skip[2], prop ? _skip[3] : 0f); }
                GTex g = _tex[texes[i]];
                if (colour)
                {
                    // the sharp relief map where there is one (read at the colour's own level), else the first kind (a level up)
                    bool sharp = g.NormHi != 0 && (ReliefSharp || g.Norm == 0);       // (a texture may have only one kind)
                    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, g.Rgb);
                    glActiveTexture(GL_TEXTURE0 + (uint)UNIT_NORM); glBindTexture(GL_TEXTURE_2D, sharp ? g.NormHi : g.Norm);
                    glUniform1f(mNormLod, sharp ? 0f : -1f); glUniform1i(mNormBands, sharp ? 1 : 0); glUniform1f(mNormTile, sharp ? Math.Max(0.25f, ReliefTile) : 1f);
                    glUniform1f(mReliefGain, sharp ? Math.Max(1f, ReliefGain) : 99f);      // (the cap goes with the new maps; the old ones light as they always did)
                    glUniform1f(mReliefTint, sharp ? Math.Max(0f, ReliefTint) : 0f);
                    glUniform1f(mReliefOp, sharp ? Math.Max(0f, Math.Min(1f, ReliefOpacity)) : 1f);
                    glUniform1f(mDetail, texes[i].Moves ? 0f : _detailNow);          // (no world-laid grain on what moves)
                    // its material: how it shines; its companion maps, if it has them
                    var tm = texes[i];
                    glUniform1f(mShine, tm.Shine * ShineGain); glUniform1f(mGloss, tm.Gloss); glUniform1f(mMetal, tm.Metal); glUniform1f(mShineVary, tm.ShineVary); glUniform1f(mWetK, tm.Wet); glUniform1f(mReliefK, tm.Relief);
                    glUniform1f(glGetUniformLocation(_pMain, "uGlass"), tm.Glass);
                    if (tm.Glass > 0f) glUniform3f(glGetUniformLocation(_pMain, "uGlassTint"), ((tm.GlassTint >> 16) & 255) / 255f, ((tm.GlassTint >> 8) & 255) / 255f, (tm.GlassTint & 255) / 255f);
                    if (MatUnitOk)
                    {
                        if (tm.MatPx != null && !ReferenceEquals(g.MatSrc, tm.MatPx)) MakeMat(tm, g);      // (new or changed maps; none = keep what the card has)
                        glActiveTexture(GL_TEXTURE0 + (uint)UNIT_MAT); glBindTexture(GL_TEXTURE_2D, g.Mat);
                        glUniform1i(mMatHas, g.Mat != 0 ? g.MatHas : 0);
                    }
                    if (DepthUnitOk)
                    {
                        bool pom = SurfacePom(tm);
                        if (pom && (!g.HeightDone || !ReferenceEquals(g.HeightSrc, tm.MatPx) || g.HeightShade != tm.ParallaxShade)) MakeHeight(tm, g);      // (a room that wants it of a texture met without; new companion maps; another shading share)
                        glActiveTexture(GL_TEXTURE0 + (uint)UNIT_HEIGHT); glBindTexture(GL_TEXTURE_2D, g.Height);
                        // (the art's plank check: grain all one way -- planks, boards -- takes none unless named by hand)
                        glUniform1f(mPomK, pom && g.Height != 0 && (tm.ParallaxSet || g.Grain <= ParallaxGrainMax) ? tm.Parallax : 0f);
                    }
                }
                // CHARACTERS DOUBLE-SIDED (Josh, 2026-10-09, Room Review LURKA/2: "the skirt texture needs to be placed on both
                // sides"): what moves (characters, creatures) is drawn with no back-face culling -- their cloth is single panels
                // (Lurka's skirt) that vanished from behind; a closed limb's back faces lie behind its front ones, so it is unchanged
                bool twoSided = colour && _culling && TwoSidedMoves && texes[i].Moves;
                if (twoSided) glDisable(GL_CULL_FACE);
                glActiveTexture(GL_TEXTURE0 + 1);
                if (!ReferenceEquals(g.ArtSrc, texes[i].ArtLight) || !ReferenceEquals(g.IdxSrc, texes[i].Idx)) RefreshMask(texes[i]);     // (new holes, or this room's light from the art)
                glBindTexture(GL_TEXTURE_2D, g.Mask);
                glDrawArrays(GL_TRIANGLES, s.Start[i] * 3, s.Count[i] * 3);
                if (twoSided) glEnable(GL_CULL_FACE);
                batches++;
            }
            if (!colour) glUniform4f(glGetUniformLocation(_pDepth, "uSkip"), 0f, 0f, 0f, 0f);      // (off again: the player's body is drawn next with the same program)
            glActiveTexture(GL_TEXTURE0);
            return batches;
        }

        // ---- drawing ----------------------------------------------------------------------------
        float[] _mirV = new float[0], _wVerts = new float[0];

        /// <summary>The same call as Raster.DrawTexturedFast, on the card -- plus whatever shadow
        /// views, water and dust were set for this frame (used up here). Clears, draws, and leaves
        /// the picture there for ReadBack.</summary>
        public void Draw(float[] vx, float[] uv, int[] idx, int[] triTex, Raster.Tex[] texes, bool cullBackfaces, bool flipV)
        {
            var sw = Stopwatch.StartNew();
            try
            {
                // the card's memory is the computer's own on this kind of machine: past a ceiling,
                // start again from the textures this room needs (a room's set goes up in ~20 ms)
                // the props (a torch...) join the room's own geometry here, so everything below treats them as room
                // the room's texture repair applies while these are the triangles it was worked out for (props join after them)
                UpdateMaterialize(vx);      // (the visor's materialize sweep: this frame's fronts)
                _relLive = RelayOn && _relFlags != null && idx.Length / 3 >= _relN && (ReferenceEquals(idx, _relIdx) || IdxSig(idx) == _relSig);
                if (_pT.Count > 0 && _pTex != null) MergeProps(ref vx, ref uv, ref idx, ref triTex, ref texes);
                Upload(texes);          // (over budget it drops the least recently used textures of other rooms first: Evict)
                Build(_main, vx, uv, idx, triTex, texes, _view);
                // a ghost in the room: where she is this frame, and her own faint light (one more placed light, no shadows)
                _nLights = _nRoomLights;
                GhostBounds(vx, idx, triTex, texes);
                AddGhostLight();
                // the pools' boxes, for the light they throw onto the room (modern water only)
                _wBoxN = 0;
                if (WaterFx)
                    for (int gi = 0; gi < _waterTris.Count && _wBoxN < 4; gi++)
                    {
                        float x0 = float.MaxValue, z0 = float.MaxValue, x1 = float.MinValue, z1 = float.MinValue;
                        foreach (int v in _waterTris[gi]) { float x = vx[v * 3], z = vx[v * 3 + 2]; if (x < x0) x0 = x; if (x > x1) x1 = x; if (z < z0) z0 = z; if (z > z1) z1 = z; }
                        int b = _wBoxN * 4; _wBox[b] = x0; _wBox[b + 1] = z0; _wBox[b + 2] = x1; _wBox[b + 3] = z1; _wYs[_wBoxN] = _waterY[gi]; _wBoxN++;
                    }

                // 1. SHADOW VIEWS: depth only, every face casts (no culling), holes do not
                int views = 0, castUp = 0; LastCasters = 0;
                glUseProgram(_pDepth);
                glUniform1f(dFlip, flipV ? 1f : 0f); glUniform1i(dNoMask, 0); glUniform1i(dMask, 1); glUniform1f(dNear, NearZ);
                glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST); glDisable(GL_BLEND);
                glColorMask(0, 0, 0, 0); glDepthMask(1); glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glClearDepth(0.0);
                for (int i = 0; i < _slots.Length; i++)
                {
                    var s = _slots[i]; if (s == null || !s.On) continue;
                    if (i < 2 && !_lampOn) continue;
                    if (i >= 2 && (i - 2 >= _nLights)) continue;
                    glBindFramebuffer(GL_FRAMEBUFFER, s.Fbo); glViewport(0, 0, s.W, s.H); glClear(GL_DEPTH_BUFFER_BIT);
                    // A TORCH CASTS NO SHADOW OF ITS OWN SCONCE (Josh, MINEMAZE/4: the stake, straight below the light, threw a round
                    // blob down the wall; a real flame is big beside the stake and washes that out). Other lights and the flashlight
                    // still see the stake.
                    _skip[0] = s.World[12]; _skip[1] = s.World[13]; _skip[2] = s.World[14]; _skip[3] = i >= 2 ? _propReach * _propReach : 0f;
                    if (s.Cube)
                    {
                        // all round: each face into its own square of the map
                        float fc = 2f * s.FocalPx / s.Face; var fw = new float[16];
                        for (int f = 0; f < 6; f++)
                        {
                            glViewport((f % 3) * s.Face, (f / 3) * s.Face, s.Face, s.Face);
                            float[] b = CubeFaces[f];
                            for (int r = 0; r < 3; r++) { fw[r * 4] = b[r * 3]; fw[r * 4 + 1] = b[r * 3 + 1]; fw[r * 4 + 2] = b[r * 3 + 2]; fw[r * 4 + 3] = 0f; }
                            fw[12] = s.World[12]; fw[13] = s.World[13]; fw[14] = s.World[14]; fw[15] = 1f;
                            glUniformMatrix4fv(dView, 1, 0, ViewOf(fw)); glUniform2f(dF, fc, fc); glUniform1f(glGetUniformLocation(_pDepth, "uOffY"), 0f);
                            DrawSet(_main, texes, false);
                            if (_castN > 0)
                            {
                                if (castUp == 0) { UploadCasters(); castUp = 1; }
                                glUniform1i(dNoMask, 1); glBindVertexArray(_cast.Vao); glDrawArrays(GL_TRIANGLES, 0, _castN * 3); glUniform1i(dNoMask, 0);
                                LastCasters = _castN;
                            }
                        }
                        views++;
                        continue;
                    }
                    float fs = 2f * s.FocalPx / s.H, asp = (float)s.W / s.H;
                    glUniformMatrix4fv(dView, 1, 0, ViewOf(s.World)); glUniform2f(dF, fs / asp, fs); glUniform1f(glGetUniformLocation(_pDepth, "uOffY"), 0f);   // a lamp's own view is centred
                    DrawSet(_main, texes, false);
                    if (i >= 2 && _castN > 0)
                    {   // the player's body, into this light's view only (no holes: solid)
                        if (castUp == 0) { UploadCasters(); castUp = 1; }
                        glUniform1i(dNoMask, 1); glBindVertexArray(_cast.Vao); glDrawArrays(GL_TRIANGLES, 0, _castN * 3); glUniform1i(dNoMask, 0);
                        LastCasters = _castN;
                    }
                    views++;
                }
                LastShadowViews = views;
                glColorMask(1, 1, 1, 1);

                // 2. THE ROOM
                glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
                glViewport(0, 0, W, H);
                glClearColor(0, 0, 0, 0); glClearDepth(0.0); glClearStencil(0);
                glDepthMask(1); glStencilMask(0xFF); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
                glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER);
                // drawn upside down (read-back rows come top first), which keeps Raster's winding: front faces CCW
                if (cullBackfaces) { glEnable(GL_CULL_FACE); glCullFace(GL_BACK); glFrontFace(GL_CCW); } else glDisable(GL_CULL_FACE); _culling = cullBackfaces;
                glUseProgram(_pMain);
                MainUniforms(flipV, false);
                LastBatches = DrawSet(_main, texes, true); LastTris = _main.Kept;

                // 3. WATER
                LastWaterGroups = 0;
                if (_waterTris.Count > 0)
                {
                    // the depth picture as it stands, for "beyond the surface" and to put back afterwards
                    Blit(_fbo, _surfFbo);
                    for (int gi = 0; gi < _waterTris.Count; gi++)
                        if (DrawWater(_waterTris[gi], _waterY[gi], vx, uv, idx, triTex, texes, cullBackfaces, flipV)) LastWaterGroups++;
                }

                // 3b. HOLOGRAMS (the intro's chalice, standing in the room)
                LastHoloSegs = 0;
                if (_holos.Count > 0) DrawHolos();
                // 3b'. THE SWEEP'S LINES THROUGH THE WALLS (the materialize sweep: the room's edges the room hides)
                LastXraySegs = 0;
                if (_matNow && _matClock != null && MatXray) DrawXray(vx, idx, triTex, texes);
            DrawEcho(vx, idx);      // (the visor's echo scan: its targets through the walls)
                if (_flames.Count > 0) DrawFlames();
                // 3c. A GHOST, as smoke over the room as it stands (before the dust and particles, her wisps among them)
                LastGhostDrawn = false;
                if (GhostOn && _ghostHave) DrawGhost(texes, flipV);
                // 4. DUST
                LastMotes = 0;
                if (_moteN > 0) { DrawMotes(); LastMotes = _moteN; }
                // 5. PARTICLES: embers, drips, steam, kicked-up dust
                LastParticles = 0;
                if (_partN > 0) { DrawParticles(); LastParticles = _partN; }
                if (MapK > 0.001f && MapUnitOk) DrawMap(vx, idx, triTex, texes);      // (the map's own layer, when it is up)

                glBindVertexArray(0);
                Check("drawing");
            }
            finally
            {
                // what was set for this frame is used up
                foreach (var s in _slots) if (s != null) s.On = false;
                _waterTris.Clear(); _waterY.Clear(); _moteN = 0; _partN = 0; _castN = 0;
            }
            LastDrawMs = sw.Elapsed.TotalMilliseconds;
        }

        void MainUniforms(bool flipV, bool refl)
        {
            glUniformMatrix4fv(mView, 1, 0, _view);
            float fpx = FocalPx;
            glUniform2f(mF, _focal * VHf / W, _focal * VHf / H); glUniform1f(glGetUniformLocation(_pMain, "uOffY"), OffY);
            glUniform1f(mNear, NearZ);
            glUniform1f(mFlip, flipV ? 1f : 0f);
            glUniform2f(mCentre, W * 0.5f, VHf * 0.5f);
            glUniform1i(mTex, 0); glUniform1i(mMask, 1);
            // the lamp
            glUniform1i(mLampOn, _lampOn ? 1 : 0);
            glUniform1f(mLampRoom, _lampRoom); glUniform1f(mLampPower, _lampPower); glUniform1f(mLampRange, _lampRange);
            glUniform1f(mSpill, _spill); glUniform1f(mHalo, _halo); glUniform1f(mFpx, fpx);
            glUniform4f(mCones, _cIn, _cOut, _cHIn, _cHOut);
            glUniform2f(mLampC, W * 0.5f + _lampCx, VHf * 0.5f + _lampCy);
            glUniform1f(mFlash, Math.Max(0f, Flash)); glUniform1f(mFlashRange, Math.Max(1f, FlashRange)); glUniform1f(mLightDeep, Math.Max(0f, Math.Min(0.9f, LightShadowDeep))); glUniform1f(mLightSoft, Math.Max(0f, LightSoft)); glUniform1f(mSoftMax, Math.Max(1f, SoftMaxTexels)); glUniform1f(mLampSoft, Math.Max(0f, LampSoft));
            glUniform3f(mFlashC, ((FlashColour >> 16) & 255) / 255f, ((FlashColour >> 8) & 255) / 255f, (FlashColour & 255) / 255f);
            // bounced light (SetGi)
            glUniform1i(glGetUniformLocation(_pMain, "uArtOn"), ArtOn ? 1 : 0);
            glUniform3f(glGetUniformLocation(_pMain, "uRoomTint"), ((RoomTint >> 16) & 255) / 255f, ((RoomTint >> 8) & 255) / 255f, (RoomTint & 255) / 255f);
            if (mGiOn == -2) { mGiOn = glGetUniformLocation(_pMain, "uGiOn"); mGi = glGetUniformLocation(_pMain, "uGi"); mGiBox = glGetUniformLocation(_pMain, "uGiBox"); mGiN = glGetUniformLocation(_pMain, "uGiN"); mGiK = glGetUniformLocation(_pMain, "uGiK"); mGiAmb = glGetUniformLocation(_pMain, "uGiAmb"); }
            glUniform1f(glGetUniformLocation(_pMain, "uLitR"), 1f / Math.Max(1f, LitReach * LitReach));
            bool giOn = GiOn && _giTex != 0;
            glUniform1i(mGiOn, giOn ? 1 : 0);
            if (giOn)
            {
                glActiveTexture(GL_TEXTURE0 + (uint)UNIT_GI); glBindTexture(GL_TEXTURE_3D, _giTex); glUniform1i(mGi, UNIT_GI);
                glUniform4f(mGiBox, _giX0, _giY0, _giZ0, 1f / _giSpacing); glUniform3i(mGiN, _giNX, _giNY, _giNZ);
                glUniform1f(mGiK, Math.Max(0f, GiStrength * GiFlicker)); glUniform1f(mGiAmb, Math.Max(0f, GiAmbient));
            }
            // its shadows
            int maps = 0; var off = new float[4];
            for (int i = 0; i < 2; i++)
            {
                var s = _slots[i]; if (s == null || !s.On || !_lampOn) break;
                glActiveTexture(GL_TEXTURE0 + (uint)(UNIT_LAMP + i)); glBindTexture(GL_TEXTURE_2D, s.Tex);
                off[i * 2] = s.Ox; off[i * 2 + 1] = s.Oy; maps++;
                if (i == 0) { glUniform3f(mLampMapF, s.FocalPx, s.W * 0.5f, s.H * 0.5f); glUniform2i(mLampMapSize, s.W, s.H); }
            }
            glUniform1i(mLampMaps, maps); glUniform1i(mLampMap0, UNIT_LAMP); glUniform1i(mLampMap1, UNIT_LAMP + 1);
            if (!refl)
            {
                _cMaps = maps; Array.Copy(off, _cOff, 4);
                for (int i = 0; i < maps; i++) _cTex[i] = _slots[i].Tex;
                if (maps > 0) { _cF[0] = _slots[0].FocalPx; _cF[1] = _slots[0].W * 0.5f; _cF[2] = _slots[0].H * 0.5f; _cSize[0] = _slots[0].W; _cSize[1] = _slots[0].H; }
            }
            glUniform2fv(mLampOff, 2, off);
            glUniform4f(mShadow, 1f + _sBias, _sSoft, _sDark, 1f + _lsBias);
            glUniform2f(mSFade, _sFar, 1f / Math.Max(1f, _sFar - _sNear));
            // placed lights into view space, as Raster does per draw; their shadow views' axes too
            var lp = new float[8 * 4]; var lc = new float[8 * 3]; var lOn = new int[8]; var ax = new float[8 * 9]; var lf = new float[8 * 2]; var lUnits = new int[8];
            float[] V = _view;
            for (int i = 0; i < 8; i++) lUnits[i] = UNIT_LIGHT + i;
            for (int i = 0; i < _nLights; i++)
            {
                float x = _lightsW[i * 8], y = _lightsW[i * 8 + 1], z = _lightsW[i * 8 + 2];
                lp[i * 4]     = x * V[0] + y * V[4] + z * V[8] + V[12];
                lp[i * 4 + 1] = x * V[1] + y * V[5] + z * V[9] + V[13];
                lp[i * 4 + 2] = x * V[2] + y * V[6] + z * V[10] + V[14];
                float rg = _lightsW[i * 8 + 6]; lp[i * 4 + 3] = (rg > 1f ? 1f / (rg * rg) : 1f) * (_oneSided[i] ? -1f : 1f);
                lc[i * 3] = _lightsW[i * 8 + 3]; lc[i * 3 + 1] = _lightsW[i * 8 + 4]; lc[i * 3 + 2] = _lightsW[i * 8 + 5];
                var s = _slots[2 + i];
                if (s != null && s.On)
                {
                    lOn[i] = s.Cube ? 2 : 1; lf[i * 2] = s.FocalPx; lf[i * 2 + 1] = s.Cube ? s.Face : s.W;
                    for (int a = 0; a < 3; a++)
                    {
                        float dx = s.World[a * 4], dy = s.World[a * 4 + 1], dz = s.World[a * 4 + 2];
                        ax[i * 9 + a * 3]     = dx * V[0] + dy * V[4] + dz * V[8];
                        ax[i * 9 + a * 3 + 1] = dx * V[1] + dy * V[5] + dz * V[9];
                        ax[i * 9 + a * 3 + 2] = dx * V[2] + dy * V[6] + dz * V[10];
                    }
                    glActiveTexture(GL_TEXTURE0 + (uint)(UNIT_LIGHT + i)); glBindTexture(GL_TEXTURE_2D, s.Tex);
                }
            }
            glUniform1i(mLightCount, _nLights);
            glUniform4fv(mLightP, 8, lp); glUniform3fv(mLightC, 8, lc);
            glUniform1iv(mLightMapOn, 8, lOn); glUniform1iv(mLightMap0, 8, lUnits);
            glUniformMatrix3fv(mLightAx, 8, 0, ax); glUniform2fv(mLightMapF, 8, lf);
            var ldir = new float[8 * 3]; var lcone = new float[8 * 2];
            for (int i = 0; i < 8; i++)
            {
                int b = i * 8; float dx = _spot[b], dy = _spot[b + 1], dz = _spot[b + 2];
                ldir[i * 3] = dx * V[0] + dy * V[4] + dz * V[8]; ldir[i * 3 + 1] = dx * V[1] + dy * V[5] + dz * V[9]; ldir[i * 3 + 2] = dx * V[2] + dy * V[6] + dz * V[10];
                bool spot = _spot[b + 4] > 0.01f;
                lcone[i * 2] = spot ? (float)Math.Cos(Math.Min(_spot[b + 3], _spot[b + 4] - 0.01f) * Math.PI / 180) : 2f; lcone[i * 2 + 1] = spot ? (float)Math.Cos(_spot[b + 4] * Math.PI / 180) : -2f;
            }
            glUniform3fv(mLightDir, 8, ldir); glUniform2fv(mLightCone, 8, lcone);
            var tm = new float[8 * 3]; var td = new float[8 * 2];
            for (int i = 0; i < 8; i++) { tm[i * 3] = _tint[i * 5]; tm[i * 3 + 1] = _tint[i * 5 + 1]; tm[i * 3 + 2] = _tint[i * 5 + 2]; td[i * 2] = _tint[i * 5 + 3]; td[i * 2 + 1] = _tint[i * 5 + 4]; }
            glUniform3fv(mLightTintM, 8, tm); glUniform2fv(mLightTintD, 8, td);
            // the lights' gates (world)
            {
                var glo = new float[8 * 4]; var ghi = new float[8 * 3]; var lw = new float[8 * 3];
                for (int i = 0; i < _nLights; i++)
                {
                    int g = i * 7; glo[i * 4 + 3] = _gate[g] > 0.5f ? 1f : 0f;
                    for (int a = 0; a < 3; a++) { glo[i * 4 + a] = _gate[g + 1 + a]; ghi[i * 3 + a] = _gate[g + 4 + a]; lw[i * 3 + a] = _lightsW[i * 8 + a]; }
                }
                glUniform4fv(glGetUniformLocation(_pMain, "uGateLo[0]"), 8, glo); glUniform3fv(glGetUniformLocation(_pMain, "uGateHi[0]"), 8, ghi); glUniform3fv(glGetUniformLocation(_pMain, "uLightW[0]"), 8, lw);
            }
            // the echo's shell (its radius from the eye, band, strength)
            {
                float er = EchoT < 0f || refl ? 0f : Math.Min(EchoMax * 1.1f, EchoT * EchoSpeed);
                float es = EchoT < 0f || refl ? 0f : EchoShell * Math.Max(0f, 1f - EchoT * EchoSpeed / (EchoMax * 1.1f));
                glUniform3f(glGetUniformLocation(_pMain, "uEcho"), er, EchoBand, es);
            }
            // the scorches (world, ages by Time)
            {
                var sp = new float[64]; var sq = new float[64]; int sn = 0;
                for (int i = 0; i < _scN && !refl; i++)
                {
                    int b = i * 8; float age = Time - _sc[b + 7]; if (age < 0f || age > ScorchLife) continue;
                    sp[sn * 4] = _sc[b]; sp[sn * 4 + 1] = _sc[b + 1]; sp[sn * 4 + 2] = _sc[b + 2]; sp[sn * 4 + 3] = _sc[b + 3];
                    sq[sn * 4] = _sc[b + 4]; sq[sn * 4 + 1] = _sc[b + 5]; sq[sn * 4 + 2] = _sc[b + 6]; sq[sn * 4 + 3] = age; sn++;
                }
                glUniform1i(glGetUniformLocation(_pMain, "uScN"), sn);
                if (sn > 0) { glUniform4fv(glGetUniformLocation(_pMain, "uScP[0]"), 16, sp); glUniform4fv(glGetUniformLocation(_pMain, "uScQ[0]"), 16, sq); glUniform1f(glGetUniformLocation(_pMain, "uScLife"), Math.Max(1f, ScorchLife)); }
            }
            // the wall washes, into view space likewise
            {
                int wn = refl ? 0 : _washN;
                // (and a shot's impact glow as one more: 6 units off the surface, shining back onto it in a wide spot, warm)
                bool imp = !refl && ImpactK > 0.01f && wn < MaxWashes;
                if (imp)
                {
                    int b = wn * WashStride; _wash[b] = ImpactAt[0]; _wash[b + 1] = ImpactAt[1]; _wash[b + 2] = ImpactAt[2]; _wash[b + 3] = ImpactRange;
                    float k = ImpactPower * ImpactK; _wash[b + 4] = ((ImpactColour >> 16) & 255) / 255f * k; _wash[b + 5] = ((ImpactColour >> 8) & 255) / 255f * k; _wash[b + 6] = (ImpactColour & 255) / 255f * k;
                    _wash[b + 7] = -ImpactAt[3]; _wash[b + 8] = -ImpactAt[4]; _wash[b + 9] = -ImpactAt[5]; _wash[b + 10] = (float)Math.Cos(75 * Math.PI / 180);      // (back at the wall: lighting round the hit) _wash[b + 11] = (float)Math.Cos(89 * Math.PI / 180);
                    wn++;
                }
                var wp = new float[MaxWashes * 4]; var wc = new float[MaxWashes * 3]; var wd = new float[MaxWashes * 3]; var wk = new float[MaxWashes * 2];
                for (int i = 0; i < wn; i++)
                {
                    int b = i * WashStride; float x = _wash[b], y = _wash[b + 1], z = _wash[b + 2], dx = _wash[b + 7], dy = _wash[b + 8], dz = _wash[b + 9];
                    wp[i * 4] = x * V[0] + y * V[4] + z * V[8] + V[12]; wp[i * 4 + 1] = x * V[1] + y * V[5] + z * V[9] + V[13]; wp[i * 4 + 2] = x * V[2] + y * V[6] + z * V[10] + V[14];
                    float rg = _wash[b + 3]; wp[i * 4 + 3] = rg > 1f ? 1f / (rg * rg) : 1f;
                    wc[i * 3] = _wash[b + 4]; wc[i * 3 + 1] = _wash[b + 5]; wc[i * 3 + 2] = _wash[b + 6];
                    wd[i * 3] = dx * V[0] + dy * V[4] + dz * V[8]; wd[i * 3 + 1] = dx * V[1] + dy * V[5] + dz * V[9]; wd[i * 3 + 2] = dx * V[2] + dy * V[6] + dz * V[10];
                    wk[i * 2] = _wash[b + 10]; wk[i * 2 + 1] = _wash[b + 11];
                }
                glUniform1i(glGetUniformLocation(_pMain, "uWashN"), wn);
                if (wn > 0)
                {
                    glUniform4fv(glGetUniformLocation(_pMain, "uWashP[0]"), MaxWashes, wp); glUniform3fv(glGetUniformLocation(_pMain, "uWashC[0]"), MaxWashes, wc);
                    glUniform3fv(glGetUniformLocation(_pMain, "uWashDir[0]"), MaxWashes, wd); glUniform2fv(glGetUniformLocation(_pMain, "uWashCone[0]"), MaxWashes, wk);
                }
            }
            // THE AIR TAKES FOUR LIGHTS: the four NEAREST the eye (Josh's fifth MINEMAZE torch, 2026-10-09 -- it was the first four
            // in the room file, so a fifth lit its walls but never glowed in the fog). _air[k]: which light is the air's k-th.
            int airN = 0;
            if (!refl)
            {
                var order = new int[_nLights]; var dist = new float[_nLights];
                // (nearest by distance over its strength in the air: a shaft with a strong "air" keeps its place among them
                // -- ORRERY, 2026-10-09: the ceiling's golden cone with four glowing blobs nearer the eye)
                for (int i = 0; i < _nLights; i++) { order[i] = i; float aw = Math.Max(0.05f, _spot[i * 8 + 5]); dist[i] = (lp[i * 4] * lp[i * 4] + lp[i * 4 + 1] * lp[i * 4 + 1] + lp[i * 4 + 2] * lp[i * 4 + 2]) / (aw * aw); }
                for (int i = 0; i < _nLights; i++) if (_airFirst[i]) dist[i] = -1f - i;      // ("airFirst": always among them -- ORRERY's beam, 2026-10-09: nearer blobs of nearly its strength in the air took its place)
                Array.Sort(dist, order); airN = Math.Min(_nLights, 4);
                for (int k = 0; k < 4; k++) _air[k] = k < airN ? order[k] : 0;
                for (int k = 0; k < 4; k++) { int i = _air[k]; Array.Copy(tm, i * 3, _vM, k * 3, 3); Array.Copy(td, i * 2, _vT, k * 2, 2); }
                // (their gates, for the air)
                for (int k = 0; k < 4; k++)
                {
                    int i = _air[k], g = i * 7; _vGLo[k * 4 + 3] = (k < airN && _gate[g] > 0.5f) ? 1f : 0f;
                    for (int a = 0; a < 3; a++) { _vGLo[k * 4 + a] = _gate[g + 1 + a]; _vGHi[k * 3 + a] = _gate[g + 4 + a]; _vLW[k * 3 + a] = _lightsW[i * 8 + a]; }
                }
            }
            if (!refl)
            {
                // the same for the air (compose): cross axes + direction per light, cone + air strength + rays, reach
                for (int k = 0; k < 4; k++)
                {
                    int i = _air[k];
                    int b = i * 8; float dx = _spot[b], dy = _spot[b + 1], dz = _spot[b + 2];
                    float ux = Math.Abs(dy) < 0.9f ? 0f : 1f, uy = Math.Abs(dy) < 0.9f ? 1f : 0f;          // (a cross axis: from world up, or x for a light facing up/down)
                    float t1x = uy * dz, t1y = -ux * dz, t1z = ux * dy - uy * dx; float tl = (float)Math.Sqrt(t1x * t1x + t1y * t1y + t1z * t1z); if (tl < 1e-6f) tl = 1; t1x /= tl; t1y /= tl; t1z /= tl;
                    float t2x = dy * t1z - dz * t1y, t2y = dz * t1x - dx * t1z, t2z = dx * t1y - dy * t1x;
                    float[][] axes = { new[] { t1x, t1y, t1z }, new[] { t2x, t2y, t2z }, new[] { dx, dy, dz } };
                    for (int a = 0; a < 3; a++)
                    {
                        float wx = axes[a][0], wy = axes[a][1], wz = axes[a][2];
                        _vB[k * 9 + a * 3] = wx * V[0] + wy * V[4] + wz * V[8]; _vB[k * 9 + a * 3 + 1] = wx * V[1] + wy * V[5] + wz * V[9]; _vB[k * 9 + a * 3 + 2] = wx * V[2] + wy * V[6] + wz * V[10];
                    }
                    _vK[k * 4] = lcone[i * 2]; _vK[k * 4 + 1] = lcone[i * 2 + 1]; _vK[k * 4 + 2] = _spot[b + 5]; _vK[k * 4 + 3] = Math.Max(0f, Math.Min(1f, _spot[b + 7])); _vR[k] = _spot[b + 6];
                }
            }
            var cax = new float[6 * 9];
            for (int f = 0; f < 6; f++) for (int a = 0; a < 3; a++)
            {
                float dx = CubeFaces[f][a * 3], dy = CubeFaces[f][a * 3 + 1], dz = CubeFaces[f][a * 3 + 2];
                cax[f * 9 + a * 3] = dx * V[0] + dy * V[4] + dz * V[8]; cax[f * 9 + a * 3 + 1] = dx * V[1] + dy * V[5] + dz * V[9]; cax[f * 9 + a * 3 + 2] = dx * V[2] + dy * V[6] + dz * V[10];
            }
            glUniformMatrix3fv(mCubeAx, 6, 0, cax);
            if (!refl)
            {
                // kept for the volumetric fog in the compose (the slots are used up once the draw ends)
                _vN = airN; Array.Copy(cax, _vAx, 54);
                for (int k = 0; k < 4; k++)
                {
                    int i = _air[k]; Array.Copy(lp, i * 4, _vP, k * 4, 4); Array.Copy(lc, i * 3, _vC, k * 3, 3);
                    var s = k < airN ? _slots[2 + i] : null; bool cube = s != null && s.On && s.Cube;
                    _vF[k * 3] = cube ? s.FocalPx : 0f; _vF[k * 3 + 1] = cube ? s.Face : 0f; _vF[k * 3 + 2] = cube ? 1f : 0f; _vTex[k] = cube ? s.Tex : 0;
                }
            }
            // fog
            glUniform1i(mFogOn, _fogOn ? 1 : 0);
            glUniform3f(mFog, _fogNear, _fogOn ? 1f / (_fogFar - _fogNear) : 0f, _fogMax);
            glUniform3f(mFogCol, (_fogColor >> 16) & 255, (_fogColor >> 8) & 255, _fogColor & 255);
            // reflection
            glUniform1i(mRefl, refl ? 1 : 0); glUniform1f(mDim, WaterDim); glUniform1i(mSurf, UNIT_SURF);
            glUniform1i(mNorm, UNIT_NORM); glUniform1f(mRelief, refl || !ReliefOn ? 0f : Relief); glUniform1f(mReliefK, 1f);
            glUniform1f(mNormFine, ReliefFine); glUniform1f(mNormMid, ReliefMid); glUniform1f(mReliefGain, 99f); glUniform1f(mReliefTint, 0f); glUniform1f(mReliefOp, 1f);
            _detailNow = refl || !ReliefOn ? 0f : Detail; glUniform1f(mDetail, _detailNow); glUniform1f(mDetailScale, Math.Max(0.05f, DetailScale)); glUniform1f(mDetailAO, DetailAO);
            glUniform1f(mDetailRough, DetailRough); glUniform1i(mDetailOct, Math.Max(1, Math.Min(6, DetailOctaves)));
            // materials: the switch, where the lamp's highlight comes from, the companion maps' unit (set per texture in DrawSet)
            glUniform1i(mShineOn, ShineOn && ShineGain > 0f && !refl ? 1 : 0); glUniform3f(mLampPos, ShineLampX, ShineLampY, 0f);
            glUniform1i(mMat, MatUnitOk ? UNIT_MAT : 0); glUniform1i(mMatHas, 0); glUniform1f(mShine, 0f); glUniform1f(mGlowK, GlowGain);
            // wet surfaces: the room's settings and its floor heights (each texture's share in DrawSet)
            bool wetNow = WetOn && WetUnitOk && _groundTex != 0 && !refl && WetStrength > 0f;
            glUniform1i(mWetOn, wetNow ? 1 : 0); glUniform1f(mWetK, 0f); glUniform1i(mGround, WetUnitOk ? UNIT_GROUND : 0);
            glUniform1i(glGetUniformLocation(_pMain, "uWetDebug"), WetDebug);
            if (wetNow)
            {
                glUniform4f(mWetA, Math.Min(1f, WetStrength), Math.Max(1f, WetHeight), WetDark, WetFloor);
                glUniform4f(mWetB, WetShine, Math.Max(1f, WetGloss), Math.Max(0f, Math.Min(1f, WetPuddles)), Math.Max(1f, WetPuddleSize));
                glUniform4f(mWetC, Math.Max(0f, Math.Min(1f, WetWalls)), Math.Max(0f, Math.Min(1f, WetCeiling)), WetDarkFrom, WetDarkTo);
                glUniform4f(mGroundBox, _gx0, _gz0, _gInv, 0f); glUniform1f(mTime, Time);
                glActiveTexture(GL_TEXTURE0 + (uint)UNIT_GROUND); glBindTexture(GL_TEXTURE_2D, _groundTex); glActiveTexture(GL_TEXTURE0);
            }
            glUniform1i(mPixelMip, PixelMip ? 1 : 0); glUniform1f(mMipK, (float)Math.Pow(2, PixelMipBias)); glUniform1f(mNormMipK, (float)Math.Pow(2, PixelMipBias + NormMipBias));
            // texture repair: the mix against repeats (the re-laid coordinates themselves go in with the vertices: Build)
            glUniform1i(mMixOn, RelayOn && MixOn ? 1 : 0); glUniform1f(mMixScale, Math.Max(0.05f, RelayMixScale)); glUniform1i(glGetUniformLocation(_pMain, "uRelayDebug"), RelayDebug ? 1 : 0);
            // parallax depth: with the relief, never in a reflection (each texture's share in DrawSet)
            glUniform1i(mPomOn, ParallaxOn && DepthUnitOk && ReliefOn && !refl && ParallaxDepth > 0f ? 1 : 0); glUniform1f(mPomK, 0f);
            glUniform1i(mHeight, DepthUnitOk ? UNIT_HEIGHT : 0);
            glUniform3f(glGetUniformLocation(_pMain, "uPom"), Math.Max(0f, ParallaxDepth), Math.Max(1f, ParallaxFar), Math.Max(2, Math.Min(64, ParallaxSteps)));
            // the materialize sweep (UpdateMaterialize): both fronts, its clock, trail, the texture front's speed, the specks
            glUniform4f(mMatz, _mfTex, Math.Max(1f, MatBand), _mfWire, _matNow && !refl ? 1f : 0f);
            glUniform4f(mMatX, _matT, Math.Max(0.05f, MatTrail), Math.Max(1f, MatSpeed), Math.Max(0f, MatDots));
            glUniform3f(mMatC, (MatColor >> 16) & 255, (MatColor >> 8) & 255, MatColor & 255); glUniform3f(mMatF, (MatFlare >> 16) & 255, (MatFlare >> 8) & 255, MatFlare & 255);
            glActiveTexture(GL_TEXTURE0 + (uint)UNIT_SURF); glBindTexture(GL_TEXTURE_2D, refl ? _surfTex : 0);
            glActiveTexture(GL_TEXTURE0);
            // the light out of the water onto the room (not into the reflection)
            uint pm = _pMain;
            glUniform1i(glGetUniformLocation(pm, "uWN"), refl ? 0 : _wBoxN);
            if (!refl && _wBoxN > 0)
            {
                glUniform4fv(glGetUniformLocation(pm, "uWBox[0]"), 4, _wBox); glUniform1fv(glGetUniformLocation(pm, "uWY[0]"), 4, _wYs);
                glUniform4f(glGetUniformLocation(pm, "uCaus"), CausStrength, Math.Max(1f, CausSize), CausSpeed, Math.Max(1f, CausHeight));
                glUniform1f(glGetUniformLocation(pm, "uCausFill"), CausFill); glUniform1f(glGetUniformLocation(pm, "uTime"), Time);
                    glUniform1i(glGetUniformLocation(pm, "uWCutN"), _wCutN); glUniform4fv(glGetUniformLocation(pm, "uWCut[0]"), 4, _wCut);
                WaterGlowUniforms(pm);
            }
        }
        void WaterGlowUniforms(uint p)
        {
            glUniform3f(glGetUniformLocation(p, "uGlowCol"), ((WaterGlowColor >> 16) & 255) / 255f, ((WaterGlowColor >> 8) & 255) / 255f, (WaterGlowColor & 255) / 255f);
            glUniform1f(glGetUniformLocation(p, "uGlowBase"), WaterGlowBase);
            glUniform1i(glGetUniformLocation(p, "uWSpotN"), _wSpotN); glUniform4fv(glGetUniformLocation(p, "uWSpot[0]"), 4, _wSpot);
        }
        // the water's own pass: where it is, the ripples, the reflection's picture, the lamp and the lights (view space, as
        // the room's pass left them)
        void WaterUniforms()
        {
            uint p = _pWater; Func<string, int> L = s => glGetUniformLocation(p, s);
            glUniformMatrix4fv(L("uView"), 1, 0, _view);
            glUniform2f(L("uF"), _focal * VHf / W, _focal * VHf / H); glUniform1f(L("uOffY"), OffY); glUniform1f(L("uNear"), NearZ);
            float[] V = _view; float tx = V[12], ty = V[13], tz = V[14];
            glUniform3f(L("uEye"), -(V[0] * tx + V[1] * ty + V[2] * tz), -(V[4] * tx + V[5] * ty + V[6] * tz), -(V[8] * tx + V[9] * ty + V[10] * tz));
            glUniform1f(L("uTime"), Time);
            glUniform4f(L("uMatz"), _mfTex, Math.Max(1f, MatBand), _mfWire, _matNow ? 1f : 0f);      // (the water fades in with the materialize sweep's texture front)
            glActiveTexture(GL_TEXTURE0 + (uint)UNIT_REFL); glBindTexture(GL_TEXTURE_2D, _reflTex); glActiveTexture(GL_TEXTURE0);
            glUniform1i(L("uReflTex"), UNIT_REFL);
            WaterGlowUniforms(p);
            glUniform1f(L("uGlow"), WaterGlow); glUniform1f(L("uDots"), WaterDots);
            glUniform4f(L("uCaus"), CausStrength, Math.Max(1f, CausSize), CausSpeed, Math.Max(1f, CausHeight));
            glUniform3f(L("uRip"), RippleSlope, Math.Max(1f, RippleSize), RippleSpeed);
            glUniform1i(L("uDropN"), DropRipple > 0f ? _dropsN : 0); glUniform4fv(L("uDrop[0]"), 16, _dropsGl); glUniform1f(L("uDropK"), DropRipple);
            glUniform1f(L("uShine"), WaterShine); glUniform1f(L("uF0"), WaterF0); glUniform1f(L("uSpec"), WaterSpec); glUniform1f(L("uDistort"), WaterDistort); glUniform1f(L("uLightSpec"), WaterLightSpec);
            glUniform1f(L("uSheen"), ShineOn ? WaterSheen * ShineGain : 0f); glUniform1f(L("uSheenGloss"), WaterSheenGloss);
            glUniform1i(L("uLampOn"), _lampOn ? 1 : 0); glUniform1f(L("uLampPower"), _lampPower); glUniform1f(L("uLampRange"), _lampRange);
            glUniform1f(L("uFpx"), FocalPx); glUniform1f(L("uSpill"), _spill); glUniform1f(L("uHalo"), _halo);
            glUniform4f(L("uCones"), _cIn, _cOut, _cHIn, _cHOut); glUniform2f(L("uLampC"), W * 0.5f + _lampCx, VHf * 0.5f + _lampCy);
            glUniform1i(L("uLightN"), _vN); glUniform4fv(L("uLightP[0]"), 4, _vP); glUniform3fv(L("uLightC[0]"), 4, _vC);
        }

        void Blit(uint from, uint to)
        {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, from); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, to);
            glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
        }

        // One pool: Raster's AddPortal(drawn) + EndPortals(keep) + DrawTexturedMasked(MaskBeyond,
        // MaskKeep, MaskDim), as stencil, a depth wipe, and the mirrored room drawn twice -- once
        // for depth, once for colour where it is nearest -- so each pixel takes its reflection once.
        bool DrawWater(int[] tris, float planeY, float[] vx, float[] uv, int[] idx, int[] triTex, Raster.Tex[] texes, bool cull, bool flipV)
        {
            int n = tris.Length / 3 * 3;
            if (_wVerts.Length < n * 5) _wVerts = new float[n * 5];
            for (int k = 0; k < n; k++) { int v = tris[k]; _wVerts[k * 5] = vx[v * 3]; _wVerts[k * 5 + 1] = vx[v * 3 + 1]; _wVerts[k * 5 + 2] = vx[v * 3 + 2]; _wVerts[k * 5 + 3] = 0f; _wVerts[k * 5 + 4] = 0f; }
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            // a. mark where the water is the nearest thing (it is in the depth picture already: a hair of tolerance)
            glEnable(GL_STENCIL_TEST); glStencilMask(0xFF); glClearStencil(0); glClear(GL_STENCIL_BUFFER_BIT);
            glStencilFunc(GL_ALWAYS, 1, 0xFF); glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
            glUseProgram(_pDepth);
            glUniformMatrix4fv(dView, 1, 0, _view); glUniform2f(dF, _focal * VHf / W, _focal * VHf / H); glUniform1f(glGetUniformLocation(_pDepth, "uOffY"), OffY); glUniform1f(dNear, NearZ); glUniform1i(dNoMask, 1);
            glColorMask(0, 0, 0, 0); glDepthMask(0); glDisable(GL_CULL_FACE);
            glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GEQUAL);
            glEnable(GL_POLYGON_OFFSET_FILL); glPolygonOffset(0f, 64f);
            glBindVertexArray(_wVao); glBindBuffer(GL_ARRAY_BUFFER, _wVbo);
            glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)n * 5 * 4), _wVerts, GL_STREAM_DRAW);
            glDrawArrays(GL_TRIANGLES, 0, n);
            glDisable(GL_POLYGON_OFFSET_FILL);
            glUniform1i(dNoMask, 0);
            // b. wipe the depth there (EndPortals): what was behind the water is not in the way of its reflection
            glStencilFunc(GL_EQUAL, 1, 0xFF); glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
            glUseProgram(_pClear); glBindVertexArray(_eVao);
            glDepthMask(1); glDepthFunc(GL_ALWAYS);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            // c. the room mirrored through the water's height
            if (_mirV.Length != vx.Length) _mirV = new float[vx.Length];
            Raster.Mirror(vx, _mirV, planeY);
            Build(_mirror, _mirV, uv, idx, triTex, texes, _view);
            if (WaterFx)
            {
                // (modern water: the reflection into its own picture, which shares this depth + stencil; alpha 1 = nothing there)
                glBindFramebuffer(GL_FRAMEBUFFER, _reflFbo);
                glColorMask(1, 1, 1, 1); glClearColor(0f, 0f, 0f, 1f); glClear(GL_COLOR_BUFFER_BIT); glClearColor(0f, 0f, 0f, 0f); glColorMask(0, 0, 0, 0);
            }
            glUseProgram(_pMain);
            MainUniforms(flipV, true);
            glUniform1f(glGetUniformLocation(_pMain, "uMirY"), planeY);
            // mirroring reverses every triangle's winding: front faces are now clockwise
            if (cull) { glEnable(GL_CULL_FACE); glCullFace(GL_BACK); glFrontFace(GL_CW); } else glDisable(GL_CULL_FACE); _culling = cull;
            glDepthFunc(GL_GREATER); glDepthMask(1);
            DrawSet(_mirror, texes, true);                 // depth: the nearest reflected surface per pixel
            glColorMask(1, 1, 1, 1); glDepthMask(0); glDepthFunc(GL_EQUAL);
            if (!WaterFx) { glEnable(GL_BLEND); glBlendColor(0f, 0f, 0f, WaterKeep); glBlendFunc(GL_ONE_MINUS_CONSTANT_ALPHA, GL_CONSTANT_ALPHA); }
            DrawSet(_mirror, texes, true);                 // colour: that surface, laid over the water's own (or into the reflection's picture)
            glDisable(GL_BLEND);
            glFrontFace(GL_CCW); glDisable(GL_STENCIL_TEST); glDepthFunc(GL_GREATER); glDepthMask(1);
            // d. the depth picture back as it was (the water surface stops dust behind it)
            Blit(_surfFbo, _fbo);
            if (WaterFx)
            {
                // e. THE SURFACE, where the water is the nearest thing (a.'s stencil, which the depth copy left alone)
                glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
                glUseProgram(_pWater); WaterUniforms();
                glDisable(GL_DEPTH_TEST); glDisable(GL_CULL_FACE);
                glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL, 1, 0xFF); glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP); glStencilMask(0);
                glColorMask(1, 1, 1, 0); glEnable(GL_BLEND);
                glBindVertexArray(_wVao);
                int pass = glGetUniformLocation(_pWater, "uPass");
                glUniform1i(pass, 0); glBlendFunc(GL_DST_COLOR, GL_ONE); glDrawArrays(GL_TRIANGLES, 0, n);     // the specks lit from below
                glUniform1i(pass, 1); glBlendFunc(GL_ONE, GL_SRC_ALPHA); glDrawArrays(GL_TRIANGLES, 0, n);     // reflection, glints, glow
                glDisable(GL_BLEND); glColorMask(1, 1, 1, 1); glStencilMask(0xFF); glDisable(GL_STENCIL_TEST);
                glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(1);
            }
            return true;
        }

        void DrawParticles()
        {
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            glUseProgram(_pPart);
            glUniformMatrix4fv(glGetUniformLocation(_pPart, "uView"), 1, 0, _view);
            glUniform2f(glGetUniformLocation(_pPart, "uF"), _focal * VHf / W, _focal * VHf / H); glUniform1f(glGetUniformLocation(_pPart, "uOffY"), OffY);
            glUniform1f(glGetUniformLocation(_pPart, "uNear"), NearZ); glUniform1f(glGetUniformLocation(_pPart, "uFpx"), FocalPx);
            // POINT SPRITES MUST BE SWITCHED ON in this (compatibility) context, or gl_PointCoord reads
            // as nothing and every particle's every pixel is thrown away (the dust motes never noticed:
            // they are shaped from gl_FragCoord instead)
            glEnable(GL_POINT_SPRITE);
            glEnable(GL_PROGRAM_POINT_SIZE); glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST);
            glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(0); glEnable(GL_BLEND);
            glColorMask(1, 1, 1, 0);      // (alpha = the placed lights' share, for the fog: specks must not change it)
            glBindVertexArray(_pVao); glBindBuffer(GL_ARRAY_BUFFER, _pVbo);
            glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)_partN * 40), _parts, GL_STREAM_DRAW);
            if (_partAlpha > 0) { glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); glDrawArrays(GL_POINTS, 0, _partAlpha); }
            if (_partN > _partAlpha) { glBlendFunc(GL_ONE, GL_ONE); glDrawArrays(GL_POINTS, _partAlpha, _partN - _partAlpha); }
            glDisable(GL_BLEND); glDepthMask(1); glDisable(GL_PROGRAM_POINT_SIZE); glDisable(GL_POINT_SPRITE); glColorMask(1, 1, 1, 1);
        }
        const uint GL_POINT_SPRITE = 0x8861;

        void DrawMotes()
        {
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            glUseProgram(_pMote);
            glUniform2f(eWH, W, H); glUniform1f(eNear, NearZ);
            glUniform3f(eCol, (_moteCol >> 16) & 255, (_moteCol >> 8) & 255, _moteCol & 255);
            glUniform3f(eDark, (_moteDark >> 16) & 255, (_moteDark >> 8) & 255, _moteDark & 255);
            glEnable(GL_PROGRAM_POINT_SIZE); glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST);
            glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(0);
            glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA); glColorMask(1, 1, 1, 0);
            glBindVertexArray(_mVao); glBindBuffer(GL_ARRAY_BUFFER, _mVbo);
            glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)_moteN * 6 * 4), _motes, GL_STREAM_DRAW);
            glDrawArrays(GL_POINTS, 0, _moteN);
            glDisable(GL_BLEND); glDepthMask(1); glDisable(GL_PROGRAM_POINT_SIZE); glColorMask(1, 1, 1, 1);
        }

        // ---- THE AIR AND THE CORNERS (drawn in the compose, from the picture's depth) ----------
        /// <summary>Corner and contact darkening: strength (0 = off) and reach in world units.</summary>
        public float AO = 0f, AORadius = 24f;
        /// <summary>Ground mist: density at the floor (per unit of distance), how fast it thins with
        /// height (units), the floor it lies on (world y), the most it ever gets, its colour, and
        /// its wisps (noise scale per unit, drift speed in units a second, how much they vary it).</summary>
        public bool MistOn; public float MistDensity = 0.0025f, MistHeight = 18f, MistFloorY = 0f, MistMax = 0.02f;
        public int MistColor = 0x6A6258; public float MistNoiseScale = 0.012f, MistNoiseSpeed = 5f, MistNoiseAmount = 0.8f;
        /// <summary>The flashlight's beam in the air: strength (0 = off), the thin haze it shows in
        /// everywhere, how much more the mist catches it, its colour.</summary>
        public float Beam = 0f, BeamHaze = 0.003f, BeamMistScatter = 0.5f; public int BeamColor = 0xFFECD6;
        /// <summary>The shaft's own cone (half-angles, degrees: full strength inside, none past the
        /// outer), narrower than the lamp's light on surfaces.</summary>
        public float BeamInnerDeg = 4f, BeamOuterDeg = 22f;
        /// <summary>The most the lit air ever adds, as a share of white.</summary>
        public float BeamMax = 0.15f;
        /// <summary>How far from the lamp the shaft is half as bright (units).</summary>
        public float BeamFalloff = 70f;
        /// <summary>Where the shaft starts, from the eye (x right, y up, z ahead, units).</summary>
        public float BeamOrgX = 0f, BeamOrgY = -18f, BeamOrgZ = 0f;      // (below the visor: the fan rises from under the view)
        /// <summary>How far, and in how many slices, the air is looked through.</summary>
        public float MarchMax = 900f; public int MarchSteps = 16;
        /// <summary>Seconds, for the wisps' drift.</summary>
        public float Time;
        float[] _kernel;
        float[] Kernel()
        {
            if (_kernel != null) return _kernel;
            var rnd = new Random(5); _kernel = new float[36];
            for (int k = 0; k < 12; k++)
            {
                double x, y, z, l;
                do { x = rnd.NextDouble() * 2 - 1; y = rnd.NextDouble() * 2 - 1; z = rnd.NextDouble(); l = Math.Sqrt(x * x + y * y + z * z); } while (l > 1 || l < 0.1 || z < 0.15);
                double sc = (k + 1) / 12.0; sc = 0.15 + 0.85 * sc * sc;
                _kernel[k * 3] = (float)(x / l * sc); _kernel[k * 3 + 1] = (float)(y / l * sc); _kernel[k * 3 + 2] = (float)(z / l * sc);
            }
            return _kernel;
        }
        // ---- phase 3: the after-passes and the compose ----------------------------------------
        public double LastPostMs, LastUploadScreenMs, LastSharpenMs, LastComposeMs;
        /// <summary>Wait for the card after each step, to time them one by one (testing only: it stalls).</summary>
        public bool TimePasses;
        /// <summary>A small palette-indexed strip (the frame counter) into the drawn picture, before
        /// the after-passes -- where Overlay.StampPal put it into Raster.Color32.</summary>
        public void Stamp(byte[] strip, int sw, int sh, int x0, int y0, int[] pal32)
        {
            if (strip == null || x0 < 0 || y0 < 0 || x0 + sw > W || y0 + sh > H) return;
            var px = new int[sw * sh];
            for (int i = 0; i < px.Length; i++) px[i] = pal32[strip[i]] & 0xFFFFFF;
            glBindTexture(GL_TEXTURE_2D, _colorTex);
            glTexSubImage2D(GL_TEXTURE_2D, 0, x0, y0, sw, sh, GL_BGRA, GL_UNSIGNED_BYTE, px);
        }
        /// <summary>Overlay.ComposeMap's tables, onto the card (only when they change).</summary>
        public void SetComposeMap(int[] cxi, int[] cxf, int[] cxiR, int[] cxfR, int[] riy, int[] rwy)
        {
            if (ReferenceEquals(_mapKey, cxi) && ReferenceEquals(_mapKeyR, cxiR) && ReferenceEquals(_mapKeyY, riy)) return;
            int mw = Math.Max(W, H); var m = new int[mw * 6];
            for (int x = 0; x < W && x < cxi.Length; x++) { m[x] = cxi[x]; m[mw + x] = cxf[x]; m[2 * mw + x] = cxiR[x]; m[3 * mw + x] = cxfR[x]; }
            for (int y = 0; y < H && y < riy.Length; y++) { m[4 * mw + y] = riy[y]; m[5 * mw + y] = rwy[y]; }
            if (_mapTex == 0) { var ids = new uint[1]; glGenTextures(1, ids); _mapTex = ids[0]; }
            glBindTexture(GL_TEXTURE_2D, _mapTex);
            glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_R32I, mw, 6, 0, GL_RED_INTEGER, GL_INT, m);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            _mapKey = cxi; _mapKeyR = cxiR; _mapKeyY = riy;
            // (where the game's view lies in the picture, for the map's lights: picture x = _cmX0 + view x * _cmSx; the view's rows)
            int c0 = -1, c1 = -1; for (int x = 0; x < W && x < cxi.Length; x++) if (cxi[x] >= 0) { if (c0 < 0) c0 = x; c1 = x; }
            _cmSx = c0 >= 0 && cxi[c1] > cxi[c0] ? (float)(c1 - c0) / (cxi[c1] - cxi[c0]) : 0f; _cmX0 = c0 >= 0 ? c0 - cxi[c0] * _cmSx : 0f;
            _cmVr = H; for (int y = 0; y < H && y < riy.Length; y++) if (riy[y] < 0) { _cmVr = y; break; }
            Check("sending the compose map");
        }
        float _cmX0, _cmSx; int _cmVr;
        /// <summary>THE VISOR'S LIGHTS ON THE MAP (Josh, 2026-10-14: "very subtle 'lights' that come from the top left and right
        /// portion of the lower UI ... as if the visor is drawing these vectors on the player's visor display ... a very light teal
        /// ... fanning inward with a natural, diffused glow ... as if this lighting was drawing the map, and then still persisting as
        /// a very faint, cone shaped glow on each side angled inward towards the map area"). Where the two lights are, in the
        /// game's VIEW pixels (x 0..1600 across the game's view, so the panel's corners lie outside it; rows from the view's top):
        /// the panel art's two corner horns (the watcher sets them from art\wide\wide.json).</summary>
        public float[] MapBeamView = { -142.6f, 823.7f, 1742.6f, 823.7f };
        /// <summary>Where they point: shares of the picture's width and of the view's rows.</summary>
        public float MapBeamAimX = 0.5f, MapBeamAimY = 0.5f;
        /// <summary>THE ANIMATION (Josh, 2026-10-14, simplified twice: "There is a second pulse from the lights that I like, and that's
        /// the only one I want to see ... that pulse with the sort of ribbing light effect ... and then the flickering spotlights as
        /// they are now ... I want that pulse to extend indefinitely and off screen, not stop at the edges ... it will span from the
        /// projection point and spread out ... then it will fade/flicker"). ONE pulse from each light: a bright band with ribs of light
        /// trailing it, running out in a fan that widens as it goes, on past the screen's edges; then the spotlights flicker in.
        /// MapBeamK: the resting spotlights' strength; MapBeamSpread: their spread (tan); MapBeamFan: the pulse's fan, full width
        /// (degrees), its top edge on the spotlight's.</summary>
        public float MapBeamK = 0.15f, MapBeamSpread = 0.22f, MapBeamFan = 40f;
        /// <summary>Seconds: the pulse's run (MapBeamPulseOut: how far it gets in it, as many reaches -- well off the screen); the
        /// spotlights melting in (from MapBeamMorphAt of the run on). MapBeamPulseK: the pulse's strength.</summary>
        public float MapBeamPulse = 1.8f, MapBeamPulseOut = 2.8f, MapBeamMorphAt = 0.5f, MapBeamMorph = 0.9f, MapBeamPulseK = 0.4f;
        /// <summary>The spotlights' strength while the pulse carries them out, as a multiple of their resting strength.</summary>
        public float MapBeamBoost = 1.6f;
        /// <summary>The cone's spread (tan) while the pulse runs -- the pulse and the spotlight riding out with it share it (Josh,
        /// 2026-10-14: 'a wider version of those initial cones, and the pulsing effect needs to adhere to those same shapes').</summary>
        public float MapBeamPulseSpread = 0.45f;
        /// <summary>The resting spotlights' flicker, always (0 = steady): the small waver, and how often (share of 1/14 s steps) and
        /// how deep a dip goes.</summary>
        public float MapBeamWaver = 0.06f, MapBeamDipOdds = 0.06f, MapBeamDip = 0.35f;
        /// <summary>When the whole run is over (s since the map opened).</summary>
        public float MapBeamRun { get { return Math.Max(MapBeamPulse, MapBeamPulse * MapBeamMorphAt + MapBeamMorph); } }
        static double FlickNoise(int i) { uint h = (uint)i * 2654435761u; h ^= h >> 13; h *= 0x5bd1e995; h ^= h >> 15; return (h & 0xFFFF) / 65535.0; }
        readonly Stopwatch _beamClock = Stopwatch.StartNew();
        /// <summary>THE MAP'S BADGE (Josh, 2026-10-14: like the "Mapping environment" one, "Accessing Map Data..." while the lights
        /// draw the map): ScanWire.cs ScanTag shows it at this strength -- from the map's opening for as long as the sweep runs
        /// (the pulse-in and the settle), then gone over 0.3 s -- its bar filling with MapTagProgress.</summary>
        public float MapTagK
        {
            get
            {
                if (!MapOn || MapK <= 0.001f || MapBeamT < 0f || !MapUnitOk) return 0f;
                float end = MapBeamRun;
                return Math.Min(1f, MapK) * (1f - Smooth01((MapBeamT - end) / 0.3f));
            }
        }
        public float MapTagProgress { get { return Smooth01(MapBeamT / Math.Max(0.1f, MapBeamRun)); } }
        /// <summary>THE ECHO SCAN'S BADGE (Josh, 2026-10-14: on the V pulse "a similar badge but in amber, which reads 'Gathering
        /// Environmental Data'"): shown while the shell runs out (and EchoTagHold s after), then gone over 0.3 s; its bar = the shell's reach.</summary>
        public float EchoTagHold = 0.6f;
        public float EchoTagK { get { if (EchoT < 0f) return 0f; float end = EchoMax / Math.Max(1f, EchoSpeed) + EchoTagHold; return 1f - Smooth01((EchoT - end) / 0.3f); } }
        public float EchoTagProgress { get { return EchoT < 0f ? 0f : Math.Min(1f, EchoT * EchoSpeed / Math.Max(1f, EchoMax)); } }
        public int MapBeamInk = 0xA6F0E6;
        /// <summary>Seconds since the map opened (the watcher; below 0 = settled).</summary>
        public float MapBeamT = -1f;
        static float Smooth01(float x) { x = Math.Max(0f, Math.Min(1f, x)); return x * x * (3f - 2f * x); }
        void SetBeamUniforms(bool mapUp, int gameH)
        {
            uint pc = _pComp; Func<string, int> L = n => glGetUniformLocation(pc, n);
            float[] e = MapBeamView;
            bool on = mapUp && MapBeamK > 0f && _cmSx > 0f && e != null && e.Length >= 4 && gameH > 0;
            glUniform3f(L("uMlK"), 0f, 0f, 0f); glUniform4f(L("uMlA"), 1f, 0.5f, 0.2f, 0f); glUniform2f(L("uMlPulse"), 0f, 0f); glUniform1f(L("uMlConeR"), 1e6f);
            if (!on) return;
            float sy = (float)_cmVr / gameH;
            float t = MapBeamT;
            float ex = _cmX0 + e[0] * _cmSx, ey = e[1] * sy, exR = _cmX0 + e[2] * _cmSx, eyR = e[3] * sy;
            float aimX = W * MapBeamAimX, aimY = _cmVr * MapBeamAimY;
            // (angles: the LEFT light's, above the picture's horizontal; the right one is its mirror) the spotlight's axis on the aim;
            // the fan's middle such that its top edge lies on the spotlight's top edge (so it melts into it), half the fan below it
            double aRest = Math.Atan2(ey - aimY, aimX - ex), fanHalf = MapBeamFan * Math.PI / 360.0;
            double aFan = aRest + Math.Atan(MapBeamSpread) - fanHalf;
            float reach = (float)Math.Sqrt((aimX - ex) * (aimX - ex) + (aimY - ey) * (aimY - ey));
            float morph = 1f, pulseR = 0f, pulseK = 0f, coneFlick = 1f, coneR = 1e6f, coneBoost = 1f, spread = MapBeamSpread;
            if (t >= 0f)
            {
                // the pulse: from the light, out past the screen's edges, its fan widening as it goes; at full strength until its
                // last quarter, where it fades out flickering
                float pa = t / Math.Max(0.1f, MapBeamPulse);
                if (pa < 1f)
                {
                    pulseR = reach * MapBeamPulseOut * (1f - (float)Math.Pow(1f - pa, 1.3));

                    pulseK = MapBeamPulseK * Smooth01(pa / 0.04f) * (1f - Smooth01((pa - 0.72f) / 0.28f));
                    if (pa > 0.72f && FlickNoise((int)(t * 24f)) < 0.45) pulseK *= (float)(0.2 + 0.5 * FlickNoise((int)(t * 24f) + 7919));
                }
                // THE SPOTLIGHTS SPREAD OUT WITH IT (Josh, 2026-10-14: "make the cone glow included in the initial pulse, spanning outward
                // with it ... a bit brighter than how it appears in its final resting version"): reaching as far as the pulse has, at
                // MapBeamBoost x their resting strength; from MapBeamMorphAt of the run they settle to it over MapBeamMorph s, flickering
                coneR = pa < 1f ? pulseR : 1e6f;
                morph = Smooth01((t - MapBeamPulse * MapBeamMorphAt) / Math.Max(0.05f, MapBeamMorph));
                coneBoost = 1f + (MapBeamBoost - 1f) * (1f - morph);
                spread = MapBeamSpread + (MapBeamPulseSpread - MapBeamSpread) * (1f - morph);      // (wide with the pulse, then the resting width)
                if (morph > 0f && morph < 1f && FlickNoise((int)(t * 24f) + 31) < 0.5 - 0.3 * morph) coneFlick = (float)(0.3 + 0.5 * FlickNoise((int)(t * 24f) + 104729));
            }
            // 4. the resting spotlights flicker a little, always, each its own way: a small waver, now and then a dip
            double ct = _beamClock.Elapsed.TotalSeconds; int step = (int)(ct * 14.0);
            Func<int, float> fl = seed =>
            {
                double w = 1.0 - MapBeamWaver * (0.5 + 0.5 * Math.Sin(ct * (7.3 + seed * 0.0001) + seed)) * FlickNoise(step + seed);
                if (FlickNoise(step * 3 + seed) < MapBeamDipOdds) w *= 1.0 - MapBeamDip * (0.5 + 0.5 * FlickNoise(step + seed * 7));
                return (float)w;
            };
            float fx = (float)Math.Cos(aFan), fy = -(float)Math.Sin(aFan);          // (rows run down: up the picture is -y)
            float cx = (float)Math.Cos(aRest), cy = -(float)Math.Sin(aRest);
            glUniform4f(L("uMlE"), ex, ey, exR, eyR);
            glUniform4f(L("uMlD"), fx, fy, -fx, fy);
            glUniform4f(L("uMlC"), cx, cy, -cx, cy);
            glUniform4f(L("uMlA"), Math.Max(1f, reach), 0f, spread, 1f);
            glUniform1f(L("uMlConeR"), coneR);
            glUniform3f(L("uMlK"), 0f, pulseK, MapBeamK * coneBoost * coneFlick);
            glUniform2f(L("uMlPulse"), pulseR, pulseK > 0f ? 1f : 0f);
            glUniform2f(L("uMlFl"), fl(11), fl(5003));
            glUniform3f(L("uMlCol"), ((MapBeamInk >> 16) & 255) / 255f, ((MapBeamInk >> 8) & 255) / 255f, (MapBeamInk & 255) / 255f);
        }
        object _mapKeyR, _mapKeyY;
        /// <summary>After Draw (and any Stamp): sharpen (if sharpen > 0), then lay the game's own
        /// drawings over the picture from `screen` -- the overlay's latest reading of the game's
        /// viewport, gameW x gameH at stridePx a row -- wherever it is not `key`. The result is
        /// left on the card for ReadComposed. SetComposeMap must have been called for this size.</summary>
        /// <summary>A rectangle of the game's viewport (x0, y0, x1, y1) whose drawings the compose
        /// ignores: the host's widescreen panel draws the opened log box there itself. Null = none.</summary>
        public int[] HideRect;
        /// <summary>A second such rectangle: the scanner's wireframe box, which the host draws itself (ScanWire.cs).</summary>
        public int[] HideRect2;
        /// <summary>View rows from this one down: the game's drawings there are left out (the widescreen
        /// panel's bleed over the view, which the host draws itself). int.MaxValue = none.</summary>
        public int HideFromRow = int.MaxValue;
        /// <summary>The game is showing a book or an inventory item close up ([0x15257C], set by StartBookViewMode): the
        /// world is not shown behind it -- black wherever the host's 3D would be (Josh, 2026-10-08). The game's own
        /// drawings (the page, the HUD) are untouched.</summary>
        public bool BlackView;
        /// <summary>THE KEY THE HOST HANDS THE GAME (0xRRGGBB; -1 = none): always see-through in the compose, besides the colour
        /// measured as the commonest in the view. Josh, 2026-10-14: closing the map, a #101010 "dead space" rectangle -- the map
        /// screen leaves much of the view black, so for the frames until the game has painted the key back over it, BLACK was the
        /// commonest colour and was taken for the key, and the real key's pixels were laid over the picture as the game's own.
        /// The key's palette entry is unique (Initialize-TrueColour), so no drawing of the game's can be mistaken for it.</summary>
        public int KeyAlso = -1;
        public void PostCompose(float sharpen, int[] screen, int stridePx, int gameW, int gameH, int key, int bandTop, int bandBot, bool visor)
        {
            if (screen == null || screen.Length < stridePx * (gameH - 1) + gameW) throw new ArgumentException("screen reading too small");
            if (_mapTex == 0) throw new InvalidOperationException("no compose map yet (SetComposeMap)");
            var sw = Stopwatch.StartNew();
            // the game's screen, as read: rows stridePx apart, of which gameW pixels are the viewport
            if (_screenTex == 0 || _screenW != gameW || _screenH != gameH)
            {
                if (_screenTex == 0) { var ids = new uint[1]; glGenTextures(1, ids); _screenTex = ids[0]; }
                glBindTexture(GL_TEXTURE_2D, _screenTex);
                glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_RGBA8, gameW, gameH, 0, GL_BGRA, GL_UNSIGNED_BYTE, IntPtr.Zero);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
                _screenW = gameW; _screenH = gameH;
            }
            // through a buffer of the card's: one plain copy into it, and the card takes it from there
            int nInts = stridePx * (gameH - 1) + gameW;
            if (_screenPbo == 0) { var ids = new uint[1]; glGenBuffers(1, ids); _screenPbo = ids[0]; }
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, _screenPbo);
            glBufferDataN(GL_PIXEL_UNPACK_BUFFER, new IntPtr((long)nInts * 4), IntPtr.Zero, GL_STREAM_DRAW);
            IntPtr dst = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, IntPtr.Zero, new IntPtr((long)nInts * 4), GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
            bool viaBuffer = dst != IntPtr.Zero;
            if (viaBuffer) { Marshal.Copy(screen, 0, dst, nInts); glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER); }
            glBindTexture(GL_TEXTURE_2D, _screenTex);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, stridePx);
            if (viaBuffer) glTexSubImage2DN(GL_TEXTURE_2D, 0, 0, 0, gameW, gameH, GL_BGRA, GL_UNSIGNED_BYTE, IntPtr.Zero);
            // (every other upload passes its own array: the buffer must not stay bound)
            glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
            if (!viaBuffer) glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, gameW, gameH, GL_BGRA, GL_UNSIGNED_BYTE, screen);
            glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
            if (TimePasses) glFinish();
            LastUploadScreenMs = sw.Elapsed.TotalMilliseconds;

            glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST); glDisable(GL_BLEND); glDisable(GL_CULL_FACE);
            glColorMask(1, 1, 1, 1); glDepthMask(0);
            glViewport(0, 0, W, H); glBindVertexArray(_eVao);
            // ONE PASS: each pixel sharpened (from the drawn picture's neighbours) and composed
            int k = (int)(sharpen * 256f);
            LastSharpenMs = 0;
            glBindFramebuffer(GL_FRAMEBUFFER, _compFbo);
            glUseProgram(_pComp);
            glUniform1i(cK, k); glUniform2i(cSize, W, H);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _colorTex);
            glActiveTexture(GL_TEXTURE0 + 1); glBindTexture(GL_TEXTURE_2D, _screenTex);
            glActiveTexture(GL_TEXTURE0 + 2); glBindTexture(GL_TEXTURE_2D, _mapTex);
            glUniform1i(cPic, 0); glUniform1i(cScreen, 1); glUniform1i(cMap, 2);
            glUniform1i(cKey, key & 0xFFFFFF); glUniform1i(glGetUniformLocation(_pComp, "uKey2"), (KeyAlso >= 0 ? KeyAlso : key) & 0xFFFFFF); glUniform1i(cBlack, BlackView ? 1 : 0); glUniform2i(cBand, bandTop, bandBot); glUniform1i(cVisor, visor ? 1 : 0);
            glUniform1f(glGetUniformLocation(_pComp, "uHideFrom"), HideFromRow == int.MaxValue ? 1e9f : (float)HideFromRow);
            { int[] hr = HideRect; glUniform4f(glGetUniformLocation(_pComp, "uHide"), hr != null ? hr[0] : 0, hr != null ? hr[1] : 0, hr != null ? hr[2] : 0, hr != null ? hr[3] : 0); }
            { int[] hr = HideRect2; glUniform4f(glGetUniformLocation(_pComp, "uHide2"), hr != null ? hr[0] : 0, hr != null ? hr[1] : 0, hr != null ? hr[2] : 0, hr != null ? hr[3] : 0); }
            {   // the map layer (DrawMap), when it is up
                bool mapUp = MapK > 0.001f && _mapLayerTex != 0 && MapUnitOk;
                glUniform1f(glGetUniformLocation(_pComp, "uMapK"), mapUp ? Math.Min(1f, MapK) : 0f); glUniform1f(glGetUniformLocation(_pComp, "uMapDim"), MapDim);
            glUniform1f(glGetUniformLocation(_pComp, "uMapLines"), Math.Max(0f, Math.Min(1f, MapLines)));
                SetBeamUniforms(mapUp, gameH);
                if (mapUp) { glActiveTexture(GL_TEXTURE0 + UNIT_MAP); glBindTexture(GL_TEXTURE_2D, _mapLayerTex); glUniform1i(glGetUniformLocation(_pComp, "uMapLayer"), UNIT_MAP); glActiveTexture(GL_TEXTURE0); }
            }
            // the air and the corners
            uint pc = _pComp; Func<string, int> L = n => glGetUniformLocation(pc, n);
            glActiveTexture(GL_TEXTURE0 + 3); glBindTexture(GL_TEXTURE_2D, _depthTex);
            glUniform1i(L("uDepth"), 3); glUniform1f(L("uNear"), NearZ); glUniform1f(L("uFpx"), FocalPx); glUniform2f(L("uCentre"), W * 0.5f, VHf * 0.5f);
            glUniformMatrix4fv(L("uCamWorld"), 1, 0, _camWorld);
            glUniform1f(L("uAO"), AO); glUniform1f(L("uAORad"), AORadius); glUniform3fv(L("uKernel[0]"), 12, Kernel());
            glUniform1i(L("uMistOn"), MistOn ? 1 : 0); glUniform4f(L("uMist"), MistDensity, Math.Max(1f, MistHeight), MistFloorY, MistMax);
            glUniform3f(L("uMistCol"), (MistColor >> 16) & 255, (MistColor >> 8) & 255, MistColor & 255);
            glUniform3f(L("uMistNoise"), MistNoiseScale, MistNoiseSpeed * MistNoiseScale, MistNoiseAmount); glUniform1f(L("uTime"), Time);
            bool beamOn = Beam > 0f && _lampOn && _lampPower > 0.001f;
            glUniform1f(L("uBeam"), beamOn ? Beam : 0f); glUniform1f(L("uHaze"), BeamHaze); glUniform1f(L("uMistScatter"), BeamMistScatter);
            glUniform3f(L("uBeamCol"), (BeamColor >> 16) & 255, (BeamColor >> 8) & 255, BeamColor & 255);
            float bIn = Math.Max(0.1f, Math.Min(BeamInnerDeg, BeamOuterDeg - 0.1f)), bOut = Math.Max(bIn + 0.1f, BeamOuterDeg);
            glUniform2f(L("uBeamCone"), (float)Math.Cos(bIn * Math.PI / 180), (float)Math.Cos(bOut * Math.PI / 180));
            glUniform3f(L("uBeamOrg"), BeamOrgX, BeamOrgY, BeamOrgZ); glUniform1f(L("uBeamMax"), BeamMax); glUniform1f(L("uBeamFall"), Math.Max(1f, BeamFalloff));
            glUniform1f(L("uMarchMax"), MarchMax); glUniform1i(L("uSteps"), Math.Max(1, MarchSteps));
            glUniform1i(L("uLampOn"), beamOn ? 1 : 0); glUniform1f(L("uLampPower"), _lampPower); glUniform1f(L("uLampRange"), _lampRange);
            glUniform1f(L("uSpill"), _spill); glUniform1f(L("uHalo"), _halo); glUniform4f(L("uCones"), _cIn, _cOut, _cHIn, _cHOut);
            glUniform2f(L("uLampC"), W * 0.5f + _lampCx, VHf * 0.5f + _lampCy);
            // the volumetric fog: its settings, the placed lights as last drawn, their all-round maps on units 6-9 (4-5: the lamp's)
            glUniform1i(L("uVolOn"), VolOn ? 1 : 0);
            if (VolOn)
            {
                glUniform4f(L("uVol"), Math.Max(0f, VolDensity), Math.Max(0f, Math.Min(1f, VolMax)), Math.Max(0f, VolScatter), Math.Max(0f, VolLamp));
                glUniform4f(L("uVol2"), Math.Max(-0.9f, Math.Min(0.9f, VolAniso)), Math.Max(1f, VolReach), Math.Max(10f, VolFar), Math.Max(1, Math.Min(64, VolSteps)));
                glUniform3f(L("uVolCol"), (VolColor >> 16) & 255, (VolColor >> 8) & 255, VolColor & 255); glUniform3f(L("uPaintCol"), (PaintColor >> 16) & 255, (PaintColor >> 8) & 255, PaintColor & 255); glUniform1f(L("uVolCut"), Math.Max(0f, Math.Min(1f, VolCut))); glUniform1f(L("uVolLit"), Math.Max(0f, Math.Min(1f, VolLit))); glUniform1f(L("uVolLitAir"), Math.Max(0f, Math.Min(1f, VolLitAir)));
                glUniform4fv(L("uVGLo[0]"), 4, _vGLo); glUniform3fv(L("uVGHi[0]"), 4, _vGHi); glUniform3fv(L("uVLW[0]"), 4, _vLW);
                glUniform1i(L("uAirBox"), AirBoxOn ? 1 : 0); if (AirBoxOn) { glUniform3f(L("uAirLo"), AirLo[0], AirLo[1], AirLo[2]); glUniform3f(L("uAirHi"), AirHi[0], AirHi[1], AirHi[2]); }
                glUniform1i(L("uVN"), _vN); glUniform4fv(L("uVLP[0]"), 4, _vP); glUniform3fv(L("uVLC[0]"), 4, _vC); glUniform3fv(L("uVLF[0]"), 4, _vF);
                glUniformMatrix3fv(L("uVCubeAx[0]"), 6, 0, _vAx); glUniformMatrix3fv(L("uVLB[0]"), 4, 0, _vB); glUniform4fv(L("uVLK[0]"), 4, _vK); glUniform1fv(L("uVLR[0]"), 4, _vR); glUniform3fv(L("uVLM[0]"), 4, _vM); glUniform2fv(L("uVLT[0]"), 4, _vT);
                var units = new int[4];
                for (int i = 0; i < 4; i++) { units[i] = 6 + i; glActiveTexture(GL_TEXTURE0 + (uint)(6 + i)); glBindTexture(GL_TEXTURE_2D, _vTex[i] != 0 ? _vTex[i] : _depthTex); }
                glUniform1iv(L("uVLMap[0]"), 4, units);
                glUniform1i(L("uPaintOn"), PaintOn && _paintTex != 0 ? 1 : 0);
                if (PaintOn && _paintTex != 0)
                {
                    glActiveTexture(GL_TEXTURE0 + 11); glBindTexture(GL_TEXTURE_2D, _paintTex); glUniform1i(L("uPaintTex"), 11);
                    glUniform4f(L("uPaintBox"), _paintX0, _paintZ0, _paintSX, _paintSZ); glUniform2f(L("uPaint"), Math.Max(0f, PaintDensity), Math.Max(0f, Math.Min(0.99f, PaintMax)));
                }
            }
            glUniform1i(L("uLampMaps"), beamOn ? _cMaps : 0);
            for (int m = 0; m < 2; m++) { glActiveTexture(GL_TEXTURE0 + (uint)(4 + m)); glBindTexture(GL_TEXTURE_2D, m < _cMaps ? _cTex[m] : 0); }
            glUniform1i(L("uLampMap[0]"), 4); glUniform1i(L("uLampMap[1]"), 5);
            glUniform2fv(L("uLampOff[0]"), 2, _cOff); glUniform3f(L("uLampMapF"), _cF[0], _cF[1], _cF[2]); glUniform2i(L("uLampMapSize"), _cSize[0], _cSize[1]);
            glUniform1f(L("uSBias"), 1f + _sBias);
            // THE FOG AT HALF SIZE (VolHalf): its march into a picture a quarter the size first, then the compose reads it
            bool volHalf = VolOn && VolHalf;
            if (volHalf)
            {
                int vw = (W + 1) / 2, vh = (H + 1) / 2;
                if (_volTex == 0 || _volW != vw || _volH != vh)
                {
                    var ids = new uint[1];
                    if (_volTex == 0) { glGenTextures(1, ids); _volTex = ids[0]; glGenFramebuffers(1, ids); _volFbo = ids[0]; }
                    glBindTexture(GL_TEXTURE_2D, _volTex);
                    glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_RGBA16F, vw, vh, 0, GL_RGBA, GL_FLOAT, IntPtr.Zero);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
                    glBindFramebuffer(GL_FRAMEBUFFER, _volFbo);
                    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _volTex, 0);
                    Complete("the fog at half size");
                    _volW = vw; _volH = vh;
                }
                glBindFramebuffer(GL_FRAMEBUFFER, _volFbo); glViewport(0, 0, vw, vh);
                glUniform1i(L("uPass"), 1);
                glDrawArrays(GL_TRIANGLES, 0, 3);
                glBindFramebuffer(GL_FRAMEBUFFER, _compFbo); glViewport(0, 0, W, H);
                glActiveTexture(GL_TEXTURE0 + 10); glBindTexture(GL_TEXTURE_2D, _volTex);
                glUniform1i(L("uVolTex"), 10); glUniform2i(L("uVolSize"), vw, vh);
            }
            glUniform1i(L("uPass"), volHalf ? 2 : 0);
            glDrawArrays(GL_TRIANGLES, 0, 3);
            glActiveTexture(GL_TEXTURE0); glBindVertexArray(0); glDepthMask(1);
            if (TimePasses) { glFinish(); LastComposeMs = sw.Elapsed.TotalMilliseconds - LastUploadScreenMs - LastSharpenMs; }
            Check("sharpening and composing");
            LastPostMs = sw.Elapsed.TotalMilliseconds;
        }
        // ---- NOT WAITING FOR THE CARD ----------------------------------------------------------
        // ReadComposed waits for every pass and then copies. Instead: StartRead right after
        // PostCompose has the card copy the finished picture into a buffer of its own and returns
        // at once; FinishRead, a frame later, takes it from there -- by then long done. The
        // picture reaches the window one loop later (a few ms), as it did through the overlay's
        // own thread before.
        // ---- THE CARD'S OWN WINDOW (optimisation pass, Josh 2026-10-08: 65-70 fps) ------------------------------
        // The finished picture goes straight from the card into a window (Overlay.GlWindow), scaled there by a Catmull-Rom
        // filter -- no read-back, no stretching on the processor, no GDI copy. The visor's shading (VisorShade: a blend
        // toward one colour by a fixed coverage) is applied on the way, exactly as VisorShade.Draw does it. Pictures the
        // processor still decorates (the boot's reveal, the scanner) arrive by PresentPicture instead.
        delegate bool D_SwapInterval(int i);
        [DllImport("gdi32.dll")] static extern int GetPixelFormat(IntPtr dc);
        PIXELFORMATDESCRIPTOR _pfd; int _pfmt;
        IntPtr _phwnd, _pdc; uint _pPresent, _shadeTex, _picTex; int _picW, _picH;
        byte[] _shadeSrc; int _shadeW, _shadeRows, _shadeCol; bool _shadeOn;
        public string PresentError; public double LastPresentMs; public long PresentedFrames;
        public bool Presenting { get { return _pdc != IntPtr.Zero; } }
        const string FS_PRESENT = @"#version 400 core
uniform sampler2D uPic; uniform ivec2 uSrc; uniform vec2 uDst;
uniform int uShadeOn; uniform sampler2D uShade; uniform int uShadeRows; uniform vec3 uShadeCol;
// THE DAMAGED VISOR (ScanWire.cs VisorDamage): the glass's layer as drawn (paint, premultiplied), its fields (fx: r crack
// field for the refraction, g grime, b the dead display past the break, a where cracks glitch), the last layer for a
// repair sweep, the hit's tearing and static, the heart's pulse at the edges, and the vitals monitor
uniform int uDmgOn; uniform sampler2D uDmgPaint, uDmgFx, uDmgPaint0, uDmgFx0; uniform float uSweep;
uniform float uLevel, uHit, uHitAge, uSeed, uTime, uBeat, uRefract, uViewRows, uDeath;
uniform int uWidOn; uniform sampler2D uWid; uniform vec4 uWidRect;
// behind the visor's open menus the damage fades away (VisorDamage.Menus): up to two rectangles, 0..1 of the window
uniform vec4 uClr0, uClr1; uniform float uClrK;
// THE VISOR'S LABEL (ScanWire.cs ScanTag: Scanning... while the room materializes), premultiplied, at window px x, y, w, h
uniform int uTagOn; uniform sampler2D uTag; uniform vec4 uTagRect;
// THE CONVERSATION (ScanWire.cs ConvTag): its badge (a second label, lower left) and the amber glow round the visor's
// edges -- strength 0..1, time (s), the view's share of the window's rows (the glow keeps off the panel below it)
uniform int uTag2On; uniform sampler2D uTag2; uniform vec4 uTag2Rect;
uniform float uConvK, uConvTime, uConvRows;
// VISOR CONDENSATION (ScanWire.cs VisorFog): how far in from the view's edges the mist reaches (0..1), time, the view's share of
// the window's rows
uniform float uFogK, uFogT, uFogRows, uFogAmt;
out vec4 oColor;
vec3 labelOver(vec3 c, vec2 wp, sampler2D t, vec4 r) {
    vec2 q = (wp - r.xy) / r.zw;
    if (q.x < 0.0 || q.y < 0.0 || q.x >= 1.0 || q.y >= 1.0) return c;
    vec4 w = texture(t, q); return c * (1.0 - w.a) + w.rgb;
}
// the glow: amber light along the view's edges (a few percent of its height deep, strongest in the corners, the bottom
// edge -- the panel's seam -- weaker), breathing slowly with a faint shimmer running round it
vec3 convGlow(vec3 c, vec2 wp) {
    if (uConvK <= 0.001) return c;
    float vh = uConvRows * uDst.y;
    if (wp.y > vh) return c;
    vec2 e = vec2(min(wp.x, uDst.x - wp.x), min(wp.y, (vh - wp.y) * 1.6)) / vh;
    float w = 0.05, gx = exp(-e.x / w), gy = exp(-e.y / w);
    float edge = max(gx, gy) + 0.35 * gx * gy;
    float ang = atan(wp.y - vh * 0.5, wp.x - uDst.x * 0.5);
    float shimmer = 0.85 + 0.15 * sin(ang * 3.0 - uConvTime * 0.9);
    float breathe = 0.80 + 0.20 * sin(uConvTime * 1.4);
    float g = clamp(edge, 0.0, 1.3) * uConvK * breathe * shimmer * 0.26;
    return c + vec3(1.0, 0.60, 0.18) * g * (1.0 - 0.5 * c);
}
vec3 tagOver(vec3 c, vec2 wp) {
    c = convGlow(c, wp);
    if (uTagOn != 0) c = labelOver(c, wp, uTag, uTagRect);
    if (uTag2On != 0) c = labelOver(c, wp, uTag2, uTag2Rect);
    return c;
}
// one picture pixel, with the visor's shading as VisorShade.Draw lays it (k + k/128, out of 256, toward the colour)
vec3 px(ivec2 p) {
    p = clamp(p, ivec2(0), uSrc - 1);
    vec3 c = texelFetch(uPic, p, 0).rgb;
    if (uShadeOn != 0 && p.y < uShadeRows) {
        float k = floor(texelFetch(uShade, p, 0).r * 255.0 + 0.5); k += floor(k / 128.0);
        c += (uShadeCol - c) * (k / 256.0);
    }
    return c;
}
vec4 cr(float t) { float t2 = t * t, t3 = t2 * t; return vec4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1.0, -1.5 * t3 + 2.0 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2); }
vec3 catmull(vec2 s) {
    ivec2 i = ivec2(floor(s)); vec2 f = s - floor(s);
    vec4 wx = cr(f.x), wy = cr(f.y);
    vec3 acc = vec3(0.0);
    for (int y = 0; y < 4; y++) {
        ivec2 r = i + ivec2(0, y - 1);
        acc += (px(r + ivec2(-1, 0)) * wx.x + px(r) * wx.y + px(r + ivec2(1, 0)) * wx.z + px(r + ivec2(2, 0)) * wx.w) * wy[y];
    }
    return acc;
}
float hash(vec2 p) { p = fract(p * vec2(443.897, 441.423)); p += dot(p, p.yx + 19.19); return fract((p.x + p.y) * p.x); }
float vn2(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f); return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y); }
float fbm2(vec2 p) { return 0.55 * vn2(p) + 0.3 * vn2(p * 2.03 + 5.1) + 0.15 * vn2(p * 4.11 + 1.7); }
// THE MIST ON THE GLASS (uFogK): ragged from the view's edges inward (the corners first, the bottom edge -- the panel's seam
// -- least), slowly drifting; the picture behind it softened and veiled pale in its own light; beads of water along its
// inner edge, each a little clear lens showing the room upside down, with a glint. uFogAmt: the room's own amount (its
// 'visorFog' strength) -- a lighter room's mist is thinner as well as narrower (Josh, 2026-10-14, WASHCORI).
float mistAt(vec2 q, float vh) {
    float ex = min(q.x, uDst.x / vh - q.x), ey = min(q.y, (1.0 - q.y) * 1.5);
    float e = min(ex, ey) - 0.35 * min(ex, 0.25) * min(ey, 0.25) / 0.25;      // (the corners reach further in)
    float n = fbm2(q * 5.0 + vec2(uFogT * 0.02, -uFogT * 0.015));
    float reach = uFogK * 0.21 * (0.6 + 0.8 * n);
    return smoothstep(reach, reach - 0.05 - 0.05 * uFogK, e);
}
vec3 condense(vec3 c, vec2 wp, vec2 s, vec2 k) {
    if (uFogK <= 0.002) return c;
    float vh = uFogRows * uDst.y;
    if (wp.y > vh) return c;
    vec2 q = wp / vh;
    float m = mistAt(q, vh);
    // THE BEAD in this cell, sized by the mist at ITS OWN middle (Josh, 2026-10-14: the droplets were 'wiped with a harsh line
    // that makes it look fake ... If they simply shrunk away instead that would sell the illusion more'): as the mist round it
    // comes and goes, each bead grows and SHRINKS AWAY to nothing -- never cut by the mist's edge
    vec2 cell = q * 24.0, ci = floor(cell), f = fract(cell) - 0.5, d = vec2(0.0);
    float rad = 0.0, dd = 2.0;
    if (hash(ci + 17.0) > 0.55) {
        vec2 off = vec2(hash(ci + 3.1), hash(ci + 7.7)) - 0.5;
        float mc = mistAt((ci + 0.5 + off * 0.5) / 24.0, vh);
        float band = mc * (1.0 - mc) * 4.0 + 0.2 * mc;
        float sz = smoothstep(0.0, 0.5, band - 0.9 * hash(ci + 23.0));      // (a wide span: each shrinks slowly as the edge recedes past it)
        rad = (0.16 + 0.26 * hash(ci + 11.0)) * sz * (0.45 + 0.55 * uFogAmt);      // (a lighter room's beads are smaller -- WASHCORI)
        if (rad > 0.012) { d = f - off * 0.5; dd = length(d) / rad; }
    }
    bool bead = dd < 1.05;
    if (m <= 0.001 && !bead) return c;
    float r = (4.0 + 14.0 * m * (0.4 + 0.6 * uFogAmt)) * k.x;      // (a lighter room blurs less)
    vec3 b = c * 0.2;
    for (int i = 0; i < 8; i++) { float a = 0.7854 * float(i) + 0.4; b += px(ivec2(s + vec2(cos(a), sin(a)) * r + 0.5)) * 0.1; }
    float lum = dot(b, vec3(0.30, 0.59, 0.11));
    float dens = m * (0.55 + 0.45 * fbm2(q * 14.0 + 3.3)) * (0.4 + 0.6 * uFogAmt);
    vec3 veil = vec3(0.60, 0.64, 0.67) * (0.30 + 0.7 * lum) + b * 0.4;      // (a pale haze even over the dark: the mist holds the light about)
    vec3 o = mix(c, mix(b, veil, 0.55), clamp(dens, 0.0, 0.92));
    if (bead) {
        vec3 lens = px(ivec2(s - d * (vh / 24.0) * 2.5 * k + 0.5));
        o = mix(o, lens * 0.8 + veil * 0.4, smoothstep(1.0, 0.7, dd));
        o *= 1.0 - 0.25 * smoothstep(0.7, 1.0, dd) * (1.0 - smoothstep(1.0, 1.05, dd));
        o += vec3(0.55) * smoothstep(0.3, 0.0, length(d / max(rad, 1e-3) - vec2(-0.35, -0.35))) * (0.25 + 0.75 * lum + 0.2);
    }
    return o;
}
void main() {
    // the window's rows count up from its bottom; the picture's rows from its top
    vec2 wp = vec2(gl_FragCoord.x, uDst.y - gl_FragCoord.y), uv = wp / uDst, k = vec2(uSrc) / uDst;
    vec2 s = wp * k - 0.5, s0 = s;
    if (uDmgOn == 0) { oColor = vec4(clamp(tagOver(condense(clamp(catmull(s), 0.0, 1.0), wp, s, k), wp), 0.0, 1.0), 1.0); return; }
    // the glass: this layer -- while the glass mends, faded in over the last one (uSweep 0..1; below 0 = none)
    vec4 fx = texture(uDmgFx, uv), paint = texture(uDmgPaint, uv);
    vec2 tx = 1.0 / vec2(textureSize(uDmgFx, 0));
    vec2 gr = vec2(texture(uDmgFx, uv + vec2(tx.x, 0.0)).r - texture(uDmgFx, uv - vec2(tx.x, 0.0)).r, texture(uDmgFx, uv + vec2(0.0, tx.y)).r - texture(uDmgFx, uv - vec2(0.0, tx.y)).r);
    if (uSweep >= 0.0) {
        float m = smoothstep(0.0, 1.0, uSweep);
        fx = mix(texture(uDmgFx0, uv), fx, m); paint = mix(texture(uDmgPaint0, uv), paint, m);
        gr = mix(vec2(texture(uDmgFx0, uv + vec2(tx.x, 0.0)).r - texture(uDmgFx0, uv - vec2(tx.x, 0.0)).r, texture(uDmgFx0, uv + vec2(0.0, tx.y)).r - texture(uDmgFx0, uv - vec2(0.0, tx.y)).r), gr, m);
    }
    // REFRACTION: the cracks' field bends what is seen through them (its slope, in window px)
    s += gr * uRefract * k;
    // THE HIT: the visor's display losing hold -- bands torn sideways, the colours split; and, low on health, now and
    // then a small one on its own
    float fr = floor(uTime * 30.0), g = uHit;
    if (uLevel > 0.5) { float amb = step(1.0 - 0.10 * (uLevel - 0.5) / 0.5, hash(vec2(floor(uTime * 8.0), uSeed + 3.1))); g = max(g, 0.28 * amb); }
    float split = 0.0;
    if (g > 0.001) {
        float band = floor(uv.y * (14.0 + 18.0 * hash(vec2(fr, 1.7))) + fr * 3.17);
        if (hash(vec2(band, uSeed + fr)) > 1.0 - 0.6 * g) s.x += (hash(vec2(band, 7.3 + uSeed)) - 0.5) * 110.0 * g * k.x;
        if (hash(vec2(fr, 9.1)) > 0.7) s.y += (hash(vec2(fr, 2.2)) - 0.5) * 18.0 * g * k.y;      // (a frame that slips)
        split = 9.0 * g;
    }
    vec3 acc = catmull(s);
    if (split > 0.0) {
        acc.r = mix(acc.r, px(ivec2(floor(s + vec2(split * k.x, 0.0) + 0.5))).r, 0.85);
        acc.b = mix(acc.b, px(ivec2(floor(s - vec2(split * k.x, -0.5 * split * k.y) + 0.5))).b, 0.85);
    }
    float lum = dot(acc, vec3(0.30, 0.59, 0.11));
    // GRIME: it dims what is behind it and holds a little of the light (a dirty lens's haze)
    acc = acc * (1.0 - fx.g * 0.6) + fx.g * vec3(0.06, 0.05, 0.035) * (0.35 + 1.5 * lum);
    // THE DEAD DISPLAY past the break: black, a few stuck columns, the liquid crystal bleeding in at its edge in inky
    // blotches with a thin oily fringe at the front
    if (fx.b > 0.003) {
        float d = fx.b, cw = max(2.0, uDst.x / 640.0), colk = hash(vec2(floor(wp.x / cw), 4.5));
        // stuck columns (a few in thirty), each its own colour, flickering
        vec3 stuck = colk > 0.965 ? vec3(hash(vec2(colk, 1.0)), hash(vec2(colk, 2.0)), hash(vec2(colk, 3.0))) * (0.55 + 0.3 * sin(uTime * 37.0 + colk * 90.0)) : vec3(0.0);
        // blocks of corrupt data, re-dealt a few times a second
        vec2 blk = floor(wp / vec2(uDst.x / 48.0, uDst.y / 60.0)); float bt = floor(uTime * 3.0 + hash(blk) * 3.0);
        float bk = hash(blk + bt * 1.37);
        vec3 junk = bk > 0.93 ? vec3(hash(blk + 0.1 + bt), hash(blk + 0.2 + bt), hash(blk + 0.3 + bt)) * 0.35 * step(0.5, fract(wp.y / max(1.0, cw * 0.7))) : vec3(0.0);
        // the liquid crystal bleeding in at the front: inky, with an oily rainbow edge
        float front = smoothstep(0.02, 0.2, d) * (1.0 - smoothstep(0.2, 0.6, d));
        vec3 fringe = 0.5 + 0.5 * cos(6.2831 * (d * 2.6 + uTime * 0.05 + vec3(0.0, 0.33, 0.67)));
        acc = mix(acc, acc * 0.25 + fringe * 0.32, front);
        acc = mix(acc, vec3(0.01, 0.0, 0.02) + (stuck + junk) * step(0.8, d), smoothstep(0.3, 0.8, d));
    }
    // the cracks, chips and scratches: lit by what is behind them
    acc = acc * (1.0 - paint.a) + paint.rgb * (0.7 + 0.9 * lum);
    // the cracks flicker while the display is hit
    if (g > 0.001) acc *= 1.0 - fx.a * g * 0.7 * hash(vec2(floor(wp.y / 2.0), fr + 0.3));
    // THE HIT'S STATIC, its red flash and the interlace dropping out
    if (uHit > 0.001) {
        float n = hash(wp * 0.37 + vec2(fr * 13.1, fr * 7.7));
        float rows = step(0.45, hash(vec2(floor(uv.y * 55.0), fr)));
        acc = mix(acc, vec3(n) * vec3(1.0, 0.92, 0.9), 0.36 * uHit * (0.3 + 0.7 * rows));
        acc *= 1.0 - 0.35 * uHit * step(0.5, fract(wp.y * 0.5));
        acc += vec3(0.38, 0.06, 0.03) * exp(-uHitAge / 0.05);
    }
    // LOW ON HEALTH: the colour drains, the visor's edges pulse red with the heart
    if (uLevel > 0.5) {
        float dl = clamp((uLevel - 0.5) / 0.5, 0.0, 1.0); float l2 = dot(acc, vec3(0.30, 0.59, 0.11));
        acc = mix(acc, vec3(l2), 0.5 * dl);
        vec2 c = (uv - vec2(0.5, 0.5 * uViewRows)) * vec2(uDst.x / uDst.y, 1.0);
        float vig = smoothstep(0.35, 1.05, length(c) * 1.25);
        acc = mix(acc, acc * 0.45 + vec3(0.55, 0.03, 0.02), vig * dl * (0.18 + 0.5 * uBeat));
    }
    // THE VITALS MONITOR, drawn by the processor, premultiplied
    if (uWidOn != 0) {
        vec2 q = (wp - uWidRect.xy) / uWidRect.zw;
        if (q.x >= 0.0 && q.y >= 0.0 && q.x < 1.0 && q.y < 1.0) { vec4 w = texture(uWid, q); acc = acc * (1.0 - w.a) + w.rgb; }
    }
    // THE DISPLAY WEARING OUT (Josh, 2026-10-10: in place of the repair's teal line, very faint scanlines and static that get
    // worse the more damage is taken): fine dark scanlines, a slow roll of brightness down the glass, and grain -- barely
    // there on a scratched visor, plain near death, and after a death (uDeath) the display failing outright
    {
        float dmg = clamp(uLevel, 0.0, 1.0), lp = max(2.0, floor(uDst.y / 360.0));
        float sl = (0.025 + 0.11 * dmg + 0.12 * uDeath) * step(lp - 1.0, mod(wp.y, lp));
        float roll = (0.012 + 0.04 * dmg) * sin(uv.y * 9.0 - uTime * 1.7) * (0.6 + 0.4 * sin(uTime * 0.37));
        float grain = (0.012 + 0.07 * dmg * dmg + 0.09 * uDeath) * (hash(wp * 0.71 + vec2(fract(uTime * 7.3) * 811.0, fract(uTime * 3.1) * 419.0)) - 0.5);
        acc = acc * (1.0 - sl) * (1.0 + roll) + grain;
        if (uDeath > 0.0) { float l3 = dot(acc, vec3(0.30, 0.59, 0.11)); acc = mix(acc, vec3(l3) * vec3(0.9, 0.82, 0.8), 0.55 * uDeath) * (1.0 - 0.35 * uDeath); }
    }
    // BEHIND AN OPEN MENU (Josh, 2026-10-10): the picture as it is -- the panel and the world behind it, no glass damage --
    // softly edged (14 window px), faded in and out with the panel
    if (uClrK > 0.0) {
        float m = 0.0;
        if (uClr0.z > uClr0.x) { vec2 e = min(uv - uClr0.xy, uClr0.zw - uv) * uDst; m = max(m, smoothstep(0.0, 14.0, min(e.x, e.y))); }
        if (uClr1.z > uClr1.x) { vec2 e = min(uv - uClr1.xy, uClr1.zw - uv) * uDst; m = max(m, smoothstep(0.0, 14.0, min(e.x, e.y))); }
        m *= uClrK;
        if (m > 0.0) acc = mix(acc, catmull(s0), m);
    }
    oColor = vec4(clamp(tagOver(condense(clamp(acc, 0.0, 1.0), wp, s0, k), wp), 0.0, 1.0), 1.0);
}";
        /// <summary>Draw into this window from now on (its pixel format is set to the context's; once per window).</summary>
        public bool AttachPresent(IntPtr hwnd)
        {
            PresentError = null;
            if (hwnd == IntPtr.Zero) { PresentError = "no window"; return false; }
            if (_phwnd == hwnd && _pdc != IntPtr.Zero) return true;
            DetachPresent();
            IntPtr dc = GetDC(hwnd);
            try
            {
                if (dc == IntPtr.Zero) throw new InvalidOperationException("no drawing surface for the window");
                var pfd = _pfd;
                if (GetPixelFormat(dc) != _pfmt && !SetPixelFormat(dc, _pfmt, ref pfd)) throw new InvalidOperationException("the window takes no OpenGL pixel format");
                if (!wglMakeCurrent(dc, _rc)) throw new InvalidOperationException("the graphics context cannot draw into the window");
                // no waiting for the display: the game's own pace is ours
                var si = Get<D_SwapInterval>("wglSwapIntervalEXT", false); if (si != null) si(0);
                if (_pPresent == 0) _pPresent = Link(VS_CLEAR, FS_PRESENT, "the picture into its window");
                _phwnd = hwnd; _pdc = dc;
                return true;
            }
            catch (Exception e) { PresentError = e.Message; if (dc != IntPtr.Zero) ReleaseDC(hwnd, dc); return false; }
            finally { wglMakeCurrent(_dc, _rc); }
        }
        public void DetachPresent()
        {
            if (_pdc != IntPtr.Zero) { try { ReleaseDC(_phwnd, _pdc); } catch { } }
            _pdc = IntPtr.Zero; _phwnd = IntPtr.Zero;
        }
        /// <summary>The visor's shading for PresentGpu: VisorShade's coverage (pw wide, rows deep) and colour; null = none.</summary>
        public void SetPresentShade(byte[] cov, int pw, int rows, int colour)
        {
            if (cov == null || pw <= 0 || rows <= 0 || cov.Length < pw * rows) { _shadeOn = false; return; }
            if (!ReferenceEquals(cov, _shadeSrc) || pw != _shadeW || rows != _shadeRows)
            {
                if (_shadeTex == 0) { var ids = new uint[1]; glGenTextures(1, ids); _shadeTex = ids[0]; }
                glBindTexture(GL_TEXTURE_2D, _shadeTex);
                glTexImage2DB(GL_TEXTURE_2D, 0, (int)GL_R8, pw, rows, 0, GL_RED, GL_UNSIGNED_BYTE, cov);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
                _shadeSrc = cov; _shadeW = pw; _shadeRows = rows;
            }
            _shadeCol = colour; _shadeOn = true;
        }
        /// <summary>The finished picture (PostCompose's), straight into the window. False = not shown (no window yet).</summary>
        public bool PresentGpu() { return PresentTex(_compTex, W, H, _shadeOn); }
        /// <summary>A picture the processor finished (decorated), into the window.</summary>
        public bool PresentPicture(int[] pic, int pw, int ph)
        {
            if (_pdc == IntPtr.Zero || pic == null || pic.Length < pw * ph) return false;
            if (_picTex == 0) { var ids = new uint[1]; glGenTextures(1, ids); _picTex = ids[0]; }
            glBindTexture(GL_TEXTURE_2D, _picTex);
            if (_picW != pw || _picH != ph)
            {
                glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, pw, ph, 0, GL_BGRA, GL_UNSIGNED_BYTE, pic);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
                _picW = pw; _picH = ph;
            }
            else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, pw, ph, GL_BGRA, GL_UNSIGNED_BYTE, pic);
            return PresentTex(_picTex, pw, ph, false);
        }
        bool PresentTex(uint tex, int tw, int th, bool shade)
        {
            if (_pdc == IntPtr.Zero || tex == 0) return false;
            var sw = Stopwatch.StartNew();
            WRECT rc; if (!GetClientRect(_phwnd, out rc)) return false;
            int ww = rc.r - rc.l, wh = rc.b - rc.t; if (ww < 16 || wh < 16) return false;
            PresentW = ww; PresentH = wh;
            if (!wglMakeCurrent(_pdc, _rc)) { PresentError = "the window can no longer be drawn into"; return false; }
            try
            {
                glBindFramebuffer(GL_FRAMEBUFFER, 0); glDrawBuffer(GL_BACK);
                PresentPass(tex, tw, th, shade, ww, wh);
                SwapBuffers(_pdc);
                Check("showing the picture in its window");
            }
            finally
            {
                glActiveTexture(GL_TEXTURE0); glBindVertexArray(0);
                wglMakeCurrent(_dc, _rc); glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
            }
            PresentedFrames++; LastPresentMs = sw.Elapsed.TotalMilliseconds;
            return true;
        }
        // the present shader over the bound target (ww x wh)
        void PresentPass(uint tex, int tw, int th, bool shade, int ww, int wh)
        {
            glViewport(0, 0, ww, wh);
            glDisable(GL_DEPTH_TEST); glDisable(GL_STENCIL_TEST); glDisable(GL_BLEND); glDisable(GL_CULL_FACE); glColorMask(1, 1, 1, 1);
            glUseProgram(_pPresent); glBindVertexArray(_eVao);
            Func<string, int> L = s => glGetUniformLocation(_pPresent, s);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex); glUniform1i(L("uPic"), 0);
            glUniform2i(L("uSrc"), tw, th); glUniform2f(L("uDst"), ww, wh);
            glUniform1i(L("uShadeOn"), shade && _shadeTex != 0 ? 1 : 0);
            if (shade && _shadeTex != 0)
            {
                glActiveTexture(GL_TEXTURE0 + 1); glBindTexture(GL_TEXTURE_2D, _shadeTex); glUniform1i(L("uShade"), 1);
                glUniform1i(L("uShadeRows"), Math.Min(_shadeRows, th));
                glUniform3f(L("uShadeCol"), ((_shadeCol >> 16) & 255) / 255f, ((_shadeCol >> 8) & 255) / 255f, (_shadeCol & 255) / 255f);
            }
            // the damaged visor (VisorDamage sets these each frame)
            bool dmg = VisorOn && _dmgPaint[0] != 0;
            glUniform1i(L("uDmgOn"), dmg ? 1 : 0);
            if (dmg)
            {
                int cur = _dmgCur, prev = 1 - _dmgCur; bool sweep = VisorSweep >= 0 && _dmgPaint[prev] != 0;
                glActiveTexture(GL_TEXTURE0 + 2); glBindTexture(GL_TEXTURE_2D, _dmgPaint[cur]); glUniform1i(L("uDmgPaint"), 2);
                glActiveTexture(GL_TEXTURE0 + 3); glBindTexture(GL_TEXTURE_2D, _dmgFx[cur]); glUniform1i(L("uDmgFx"), 3);
                glActiveTexture(GL_TEXTURE0 + 4); glBindTexture(GL_TEXTURE_2D, sweep ? _dmgPaint[prev] : _dmgPaint[cur]); glUniform1i(L("uDmgPaint0"), 4);
                glActiveTexture(GL_TEXTURE0 + 5); glBindTexture(GL_TEXTURE_2D, sweep ? _dmgFx[prev] : _dmgFx[cur]); glUniform1i(L("uDmgFx0"), 5);
                glUniform1f(L("uSweep"), sweep ? VisorSweep : -1f);
                glUniform1f(L("uLevel"), VisorLevel); glUniform1f(L("uHit"), VisorHit); glUniform1f(L("uHitAge"), VisorHitAge); glUniform1f(L("uSeed"), VisorSeed);
                glUniform1f(L("uTime"), VisorTime); glUniform1f(L("uBeat"), VisorBeat); glUniform1f(L("uRefract"), VisorRefract * ww / 1920f); glUniform1f(L("uViewRows"), VisorViewRows); glUniform1f(L("uDeath"), VisorDeath);
                bool wid = VisorWidget && _widTex != 0;
                glUniform1i(L("uWidOn"), wid ? 1 : 0);
                if (wid)
                {
                    glActiveTexture(GL_TEXTURE0 + 6); glBindTexture(GL_TEXTURE_2D, _widTex); glUniform1i(L("uWid"), 6);
                    glUniform4f(L("uWidRect"), _widX, _widY, _widW, _widH);
                }
                // behind the open menus: the damage cleared
                var vc = VisorClear; float vk = vc != null && vc.Length >= 4 ? VisorClearK : 0f;
                glUniform1f(L("uClrK"), vk);
                glUniform4f(L("uClr0"), vk > 0 ? vc[0] : 0f, vk > 0 ? vc[1] : 0f, vk > 0 ? vc[2] : 0f, vk > 0 ? vc[3] : 0f);
                glUniform4f(L("uClr1"), vk > 0 && vc.Length >= 8 ? vc[4] : 0f, vk > 0 && vc.Length >= 8 ? vc[5] : 0f, vk > 0 && vc.Length >= 8 ? vc[6] : 0f, vk > 0 && vc.Length >= 8 ? vc[7] : 0f);
            }
            // the visor's label (ScanTag)
            bool tag = TagOn && _tagTex != 0;
            glUniform1i(L("uTagOn"), tag ? 1 : 0);
            if (tag) { glActiveTexture(GL_TEXTURE0 + 7); glBindTexture(GL_TEXTURE_2D, _tagTex); glUniform1i(L("uTag"), 7); glUniform4f(L("uTagRect"), _tagX, _tagY, _tagW, _tagH); glActiveTexture(GL_TEXTURE0); }
            // the conversation's badge and glow (ConvTag)
            bool tag2 = Tag2On && _tag2Tex != 0;
            glUniform1i(L("uTag2On"), tag2 ? 1 : 0);
            if (tag2) { glActiveTexture(GL_TEXTURE0 + 8); glBindTexture(GL_TEXTURE_2D, _tag2Tex); glUniform1i(L("uTag2"), 8); glUniform4f(L("uTag2Rect"), _tag2X, _tag2Y, _tag2W, _tag2H); glActiveTexture(GL_TEXTURE0); }
            glUniform1f(L("uConvK"), ConvGlow); glUniform1f(L("uConvTime"), ConvTime); glUniform1f(L("uConvRows"), ConvRows > 0 ? ConvRows : 1f);
            glUniform1f(L("uFogK"), Math.Max(0f, Math.Min(1f, VisorFog))); glUniform1f(L("uFogT"), VisorFogTime); glUniform1f(L("uFogRows"), VisorFogRows > 0 ? VisorFogRows : 1f); glUniform1f(L("uFogAmt"), Math.Max(0f, Math.Min(1f, VisorFogAmount)));
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        /// <summary>The visor's label (ScanWire.cs ScanTag; premultiplied ARGB, top row first) at window px x, y (its top
        /// left), laid over the picture in the present pass while TagOn.</summary>
        public bool TagOn;
        uint _tagTex; int _tagTW, _tagTH; float _tagX, _tagY, _tagW, _tagH;
        public void SetTag(int[] px, int w, int h, float x, float y)
        {
            if (px == null || w <= 0 || h <= 0) { TagOn = false; return; }
            if (_tagTex == 0) _tagTex = NewLinearTex();
            glBindTexture(GL_TEXTURE_2D, _tagTex);
            if (w != _tagTW || h != _tagTH) { glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0); glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, px); _tagTW = w; _tagTH = h; }
            else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, px);
            _tagX = x; _tagY = y; _tagW = w; _tagH = h; TagOn = true;
        }
        /// <summary>The conversation's badge (ScanWire.cs ConvTag), as SetTag; and the amber glow round the visor's edges:
        /// strength 0..1, time (s), the view's share of the window's rows.</summary>
        public bool Tag2On; public float ConvGlow, ConvTime, ConvRows = 1f;
        /// <summary>VISOR CONDENSATION (ScanWire.cs VisorFog sets these each frame): how far the mist reaches in from the
        /// view's edges (0 = none, 1 = about a third of the view's height), time, the view's share of the window's rows.</summary>
        public float VisorFog, VisorFogTime, VisorFogRows = 1f, VisorFogAmount = 1f;      // (VisorFogAmount: the room's own amount -- its "visorFog" strength -- for the mist's thickness)
        uint _tag2Tex; int _tag2TW, _tag2TH; float _tag2X, _tag2Y, _tag2W, _tag2H;
        public void SetTag2(int[] px, int w, int h, float x, float y)
        {
            if (px == null || w <= 0 || h <= 0) { Tag2On = false; return; }
            if (_tag2Tex == 0) _tag2Tex = NewLinearTex();
            glBindTexture(GL_TEXTURE_2D, _tag2Tex);
            if (w != _tag2TW || h != _tag2TH) { glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0); glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, px); _tag2TW = w; _tag2TH = h; }
            else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, px);
            _tag2X = x; _tag2Y = y; _tag2W = w; _tag2H = h; Tag2On = true;
        }
        // ---- THE DAMAGED VISOR (Josh, 2026-10-10): see ScanWire.cs VisorDamage, which draws the glass's layer and the vitals
        // monitor and sets these each frame; the present pass lays them over the picture (FS_PRESENT) ---------------------
        /// <summary>The visor's damage in the present pass: on, damage 0..1, the hit's strength 0..1 and age (s), a seed for
        /// the hit's tearing, time (s), the heart's pulse 0..1, the cracks' refraction (px at 1920 wide), the repair sweep's
        /// line (0..1 down the window; below 0 = none), the view's share of the window's rows, the vitals monitor on.</summary>
        public bool VisorOn, VisorWidget; public float VisorLevel, VisorHit, VisorHitAge = 9, VisorSeed, VisorTime, VisorBeat, VisorRefract = 3.5f, VisorSweep = -1, VisorViewRows = 1, VisorDeath;
        /// <summary>Behind the visor's open menus the damage is cleared: up to two rectangles (x0, y0, x1, y1, 0..1 of the
        /// window) and how far it is faded in (0..1). Null / 0 = none.</summary>
        public volatile float[] VisorClear; public float VisorClearK;
        /// <summary>The present window's size at the last present (the damage layer is drawn for it).</summary>
        public int PresentW, PresentH;
        uint[] _dmgPaint = new uint[2], _dmgFx = new uint[2]; int _dmgCur; uint _widTex; int _widTW, _widTH; float _widX, _widY, _widW, _widH;
        static uint NewLinearTex()
        {
            var ids = new uint[1]; glGenTextures(1, ids); glBindTexture(GL_TEXTURE_2D, ids[0]);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_CLAMP_TO_EDGE);
            return ids[0];
        }
        /// <summary>A new layer for the glass (premultiplied ARGB paint, top row first; fx packed A glitch, R crack field,
        /// G grime, B dead). The one it replaces is kept for a repair sweep (VisorSweep).</summary>
        public void SetVisorLayer(int[] paint, int pw, int ph, int[] fx, int fw, int fh)
        {
            if (paint == null || fx == null) return;
            int slot = _dmgPaint[_dmgCur] == 0 ? _dmgCur : 1 - _dmgCur;
            if (_dmgPaint[slot] == 0) { _dmgPaint[slot] = NewLinearTex(); _dmgFx[slot] = NewLinearTex(); }
            glBindTexture(GL_TEXTURE_2D, _dmgPaint[slot]); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, pw, ph, 0, GL_BGRA, GL_UNSIGNED_BYTE, paint);
            glBindTexture(GL_TEXTURE_2D, _dmgFx[slot]); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, fw, fh, 0, GL_BGRA, GL_UNSIGNED_BYTE, fx);
            _dmgCur = slot;
            Check("the visor's damage layer");
        }
        /// <summary>The vitals monitor (premultiplied ARGB, top row first) at window px x, y (its top left).</summary>
        public void SetVisorWidget(int[] px, int w, int h, float x, float y)
        {
            if (px == null || w <= 0 || h <= 0) { VisorWidget = false; return; }
            if (_widTex == 0) _widTex = NewLinearTex();
            glBindTexture(GL_TEXTURE_2D, _widTex);
            if (w != _widTW || h != _widTH) { glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0); glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, w, h, 0, GL_BGRA, GL_UNSIGNED_BYTE, px); _widTW = w; _widTH = h; }
            else glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, px);
            _widX = x; _widY = y; _widW = w; _widH = h; VisorWidget = true;
        }
        /// <summary>OFFLINE: a picture (0x00RRGGBB, top row first) through the present pass into a ww x wh image, as the
        /// window would show it (top row first).</summary>
        public int[] PresentOffscreen(int[] pic, int pw, int ph, int ww, int wh)
        {
            if (_pPresent == 0) _pPresent = Link(VS_CLEAR, FS_PRESENT, "the picture into its window");
            if (_picTex == 0) { var ids0 = new uint[1]; glGenTextures(1, ids0); _picTex = ids0[0]; }
            glBindTexture(GL_TEXTURE_2D, _picTex);
            glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, pw, ph, 0, GL_BGRA, GL_UNSIGNED_BYTE, pic);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
            _picW = pw; _picH = ph; PresentW = ww; PresentH = wh;
            var ids = new uint[1]; glGenFramebuffers(1, ids); uint fb = ids[0]; glBindFramebuffer(GL_FRAMEBUFFER, fb);
            glGenTextures(1, ids); uint t = ids[0]; glBindTexture(GL_TEXTURE_2D, t);
            glTexImage2D(GL_TEXTURE_2D, 0, (int)GL_RGBA8, ww, wh, 0, GL_BGRA, GL_UNSIGNED_BYTE, null);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0);
            var outp = new int[ww * wh];
            try
            {
                glDrawBuffer(GL_COLOR_ATTACHMENT0);
                PresentPass(_picTex, pw, ph, false, ww, wh);
                glReadBuffer(GL_COLOR_ATTACHMENT0); glReadPixels(0, 0, ww, wh, GL_BGRA, GL_UNSIGNED_BYTE, outp);
                Check("the present pass, offline");
            }
            finally { glActiveTexture(GL_TEXTURE0); glBindVertexArray(0); glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glDeleteTextures(1, new[] { t }); glDeleteFramebuffers(1, new[] { fb }); }
            // (read bottom row first: turn it over)
            var flip = new int[ww * wh]; for (int y = 0; y < wh; y++) Array.Copy(outp, (wh - 1 - y) * ww, flip, y * ww, ww);
            return flip;
        }
        // ---- PROPS: SOLID OBJECTS THE ROOM NEVER HAD (Josh, 2026-10-08, Room Review CORICORI/7: "build a torch shaped mesh ...
        // a wooden stake like portion, topped with a cylindrical piece of metal which would contain the flame. Adhere it to this
        // light source in a natural way") ---------------------------------------------------------------------------------
        // Built here as triangles of the room's own kind -- added to the room's geometry in Draw, so they are lit, shadowed,
        // relief-mapped and fogged like any wall -- with textures made here (wood, iron, charred coals). Two-sided (an open cup
        // is seen inside). THE TORCH is a wall sconce: an iron plate on the wall, an arm out to a ring, a wooden stake in the
        // ring leaning a little out from the wall, an iron cup on top with coals in it, its mouth just under the light.
        readonly List<float> _pV = new List<float>(), _pUV = new List<float>(); readonly List<int> _pT = new List<int>(), _pTri = new List<int>();
        Raster.Tex[] _pTex; public int PropTris { get { return _pT.Count / 3; } }
        public void ClearProps() { _pV.Clear(); _pUV.Clear(); _pT.Clear(); _pTri.Clear(); _flames.Clear(); _propReach = 0f; }
        float _propReach; readonly float[] _skip = new float[4];      // (how far a sconce reaches from its light: its own light's shadow view leaves it out)
        /// <summary>A torch in a wall sconce for a light at (lx, ly, lz) whose way into the room is (nx, nz) (the wall's
        /// normal); scale 1 = a torch about 22 units long. The light stays where it is: the cup's mouth sits just below it.</summary>
        public void AddTorch(float lx, float ly, float lz, float nx, float nz, float scale, float wallDist)
        {
            EnsurePropTextures();
            float nl = (float)Math.Sqrt(nx * nx + nz * nz); if (nl < 1e-4f) { nx = 0; nz = 1; nl = 1; } nx /= nl; nz /= nl;
            float s = Math.Max(0.2f, scale), th = 20f * (float)Math.PI / 180f;
            _propReach = Math.Max(_propReach, (float)Math.Sqrt(24f * s * 24f * s + (wallDist + 4f * s) * (wallDist + 4f * s)) + 4f);
            // the torch's axis: up, leaning out from the wall
            float ax = nx * (float)Math.Sin(th), ay = (float)Math.Cos(th), az = nz * (float)Math.Sin(th);
            float[] L = { lx, ly, lz }, A = { ax, ay, az };
            Func<float[], float, float[]> Along = (p, d) => new[] { p[0] + ax * d, p[1] + ay * d, p[2] + az * d };
            float[] rim = Along(L, -3f * s), cupBot = Along(rim, -6f * s), stakeBot = Along(rim, -21f * s), ring = Along(rim, -11.5f * s);
            // the cup: flared iron, open at the top, a rim band, coals inside; the stake below it, tapering; the holder ring
            Lathe(cupBot, A, null, new[] { 1.0f * s, 2.3f * s, 3.4f * s }, new[] { 0f, 0.5f * s, 6f * s }, 12, 1, false);
            Lathe(Along(rim, -1.3f * s), A, null, new[] { 3.8f * s, 3.8f * s }, new[] { 0f, 1.5f * s }, 12, 1, true);
            Disc(Along(rim, -1.8f * s), A, 3.1f * s, 12, 2);
            Lathe(stakeBot, A, null, new[] { 1.0f * s, 1.25f * s, 1.45f * s }, new[] { 0f, 9f * s, 15.2f * s }, 8, 0, true);
            Disc(stakeBot, A, 1.0f * s, 8, 0);
            Lathe(Along(ring, -1.4f * s), A, null, new[] { 2.0f * s, 2.0f * s }, new[] { 0f, 2.8f * s }, 10, 1, true);
            // the arm: from the ring straight back to the wall (wallDist from the light, along the wall's normal), and the plate
            float back = wallDist + (ring[0] - lx) * nx + (ring[2] - lz) * nz;          // how far the ring is from the wall (it leans in toward it below the light; the old sign pushed the arm 10 units into the wall)
            float[] armA = { ring[0] - nx * 1.8f * s, ring[1], ring[2] - nz * 1.8f * s }, wallP = { ring[0] - nx * back, ring[1], ring[2] - nz * back };
            float[] armDir = { -nx, 0f, -nz };
            Lathe(armA, armDir, null, new[] { 0.75f * s, 0.75f * s }, new[] { 0f, Math.Max(0.5f, back - 1.8f * s) }, 6, 1, true);
            Box(wallP, nx, nz, 0.9f * s, 6f * s, 11f * s, 1);
            // its flame, rising out of the coals (upright, whatever the torch's lean); the light sits in its lower middle
            AddFlame(rim[0], rim[1] - 1.2f * s, rim[2], 13f * s, 6.6f * s);
        }
        // ---- FLAMES (Josh, round 10: "add a very modern flame effect on top (not the particle effect ... something more
        // realistic). The light would be emitting from that flame") -------------------------------------------------------
        // A shader flame, not particles: sheets that always face the eye (turning only round the upright, so the flame stays
        // upright), each drawn by noise rising through a teardrop -- turbulence scrolled upward, the body swaying more the
        // higher it goes, tongues tearing off near the tip -- coloured by its heat (a white-yellow core, orange, a deep red
        // edge, a breath of blue at the base). Two sheets (an outer one and a smaller, hotter core with its own noise) for
        // depth, and a soft glow round it. Added to the picture, behind whatever is in front (its cup hides its foot).
        class Flame { public float X, Y, Z, H, W, Seed; }
        readonly List<Flame> _flames = new List<Flame>();
        public void ClearFlames() { _flames.Clear(); }
        public void AddFlame(float x, float y, float z, float height, float width) { _flames.Add(new Flame { X = x, Y = y, Z = z, H = Math.Max(1f, height), W = Math.Max(0.5f, width), Seed = _flames.Count * 1.37f + 0.21f }); }
        public float FlameBright = 1.0f;
        uint _pFlame, _fVao, _fVbo; float[] _fVerts = new float[0];
        const string VS_FLAME = @"#version 400 core
layout(location = 0) in vec3 aC; layout(location = 1) in vec2 aCorner; layout(location = 2) in vec3 aSize;   // centre of the base; (-1..1, 0..1); width, height, seed
uniform mat4 uView; uniform vec2 uF; uniform float uNear, uOffY; uniform vec3 uEye;
out vec2 vUV; out float vSeed;
void main() {
    vec3 up = vec3(0.0, 1.0, 0.0), to = uEye - aC; to.y = 0.0;
    vec3 right = dot(to, to) > 1e-6 ? normalize(cross(up, to)) : vec3(1.0, 0.0, 0.0);
    vec3 w = aC + right * (aCorner.x * aSize.x * 0.5) + up * (aCorner.y * aSize.y);
    vec4 p = uView * vec4(w, 1.0);
    gl_Position = vec4(p.x * uF.x, -p.y * uF.y + uOffY * p.z, uNear, p.z);
    vUV = aCorner; vSeed = aSize.z;
}";
        const string FS_FLAME = @"#version 400 core
in vec2 vUV; in float vSeed;
uniform float uTime, uBright; uniform int uMode;      // 0 = a flame sheet, 1 = its glow
out vec4 oColor;
float h21(vec2 p) { p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float vn(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y); }
float fbm(vec2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { s += a * vn(p); p = p * 2.03 + vec2(1.7, 9.2); a *= 0.5; } return s; }
void main() {
    float t = uTime + vSeed * 10.0;
    // the flame's breath: its brightness and height move a little, irregularly
    float breath = 0.85 + 0.15 * vn(vec2(t * 3.1, vSeed * 7.0)) + 0.08 * vn(vec2(t * 9.0, vSeed));
    if (uMode == 1) {
        vec2 d = vec2(vUV.x, (vUV.y - 0.42) * 1.6);
        float g = exp(-dot(d, d) * 3.2) * 0.16 * breath;
        oColor = vec4(vec3(1.0, 0.52, 0.18) * g * uBright, min(g * 3.0, 0.5));
        return;
    }
    vec2 q = vec2(vUV.x * 1.7, vUV.y * 2.3 - t * 1.9);
    float n = fbm(q + vec2(vSeed * 3.1, 0.0)), n2 = fbm(q * 2.1 + vec2(-t * 0.35, 5.0));
    float y = vUV.y / breath;
    float x = vUV.x + (n - 0.5) * 0.95 * y + sin(t * 2.3 + vSeed * 6.0) * 0.07 * y;
    // the teardrop: widest a little above the base, drawn to a point at the top
    float width = 0.66 * pow(max(1.0 - y, 0.0), 0.7) * smoothstep(0.0, 0.14, y + 0.03);
    float body = 1.0 - smoothstep(width * 0.5, width + 1e-3, abs(x));
    float tongue = smoothstep(0.38, 0.72, n2);
    float dens = body * mix(1.0, tongue * 1.5, smoothstep(0.3, 0.95, y)) * (1.0 - smoothstep(0.78, 1.0, y + (n - 0.5) * 0.35));
    // heat: hottest low in the middle
    float heat = dens * (1.0 - y * 0.8) * (1.0 - abs(x) / max(width, 1e-3) * 0.55);
    vec3 c = mix(vec3(0.5, 0.07, 0.01), vec3(1.0, 0.42, 0.07), smoothstep(0.06, 0.38, heat));
    c = mix(c, vec3(1.0, 0.8, 0.42), smoothstep(0.34, 0.68, heat));
    c = mix(c, vec3(1.0, 0.97, 0.86), smoothstep(0.62, 0.92, heat));
    c = mix(c, vec3(0.2, 0.32, 1.0) * 0.7, smoothstep(0.13, 0.0, y) * body * 0.45);     // the blue at its root
    float a = clamp(dens * 1.5, 0.0, 1.0);
    oColor = vec4(c * a * uBright * breath, a);
}";
        void DrawFlames()
        {
            int n = _flames.Count * 3 * 6;                       // per flame: glow, outer sheet, core sheet; 6 vertices each
            if (_fVerts.Length < n * 8) _fVerts = new float[n * 8];
            int k = 0;
            Action<Flame, float, float, float, float> Sheet = (f, wk, hk, seed, lift) =>
            {
                float[][] cr = { new[] { -1f, 0f }, new[] { 1f, 0f }, new[] { 1f, 1f }, new[] { -1f, 0f }, new[] { 1f, 1f }, new[] { -1f, 1f } };
                foreach (var c in cr)
                {
                    int o = k * 8; _fVerts[o] = f.X; _fVerts[o + 1] = f.Y + lift; _fVerts[o + 2] = f.Z; _fVerts[o + 3] = c[0]; _fVerts[o + 4] = c[1];
                    _fVerts[o + 5] = f.W * wk; _fVerts[o + 6] = f.H * hk; _fVerts[o + 7] = seed; k++;
                }
            };
            foreach (var f in _flames) { Sheet(f, 3.2f, 1.6f, f.Seed, -f.H * 0.25f); Sheet(f, 1f, 1f, f.Seed, 0f); Sheet(f, 0.62f, 0.72f, f.Seed + 1.7f, 0f); }
            if (_pFlame == 0)
            {
                _pFlame = Link(VS_FLAME, FS_FLAME, "flames");
                var ids = new uint[1]; glGenVertexArrays(1, ids); _fVao = ids[0]; glBindVertexArray(_fVao);
                glGenBuffers(1, ids); _fVbo = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _fVbo);
                glEnableVertexAttribArray(0); glVertexAttribPointer(0, 3, GL_FLOAT, 0, 32, IntPtr.Zero);
                glEnableVertexAttribArray(1); glVertexAttribPointer(1, 2, GL_FLOAT, 0, 32, new IntPtr(12));
                glEnableVertexAttribArray(2); glVertexAttribPointer(2, 3, GL_FLOAT, 0, 32, new IntPtr(20));
            }
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            glUseProgram(_pFlame); Func<string, int> L = s => glGetUniformLocation(_pFlame, s);
            glUniformMatrix4fv(L("uView"), 1, 0, _view); glUniform2f(L("uF"), _focal * VHf / W, _focal * VHf / H);
            glUniform1f(L("uNear"), NearZ); glUniform1f(L("uOffY"), OffY); glUniform1f(L("uTime"), Time); glUniform1f(L("uBright"), FlameBright);
            float[] V = _view; float tx = V[12], ty = V[13], tz = V[14];
            glUniform3f(L("uEye"), -(V[0] * tx + V[1] * ty + V[2] * tz), -(V[4] * tx + V[5] * ty + V[6] * tz), -(V[8] * tx + V[9] * ty + V[10] * tz));
            glBindVertexArray(_fVao); glBindBuffer(GL_ARRAY_BUFFER, _fVbo);
            glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)k * 32), _fVerts, GL_STREAM_DRAW);
            glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(0); glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST);
            glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE); glColorMask(1, 1, 1, 1);
            // the glows first (every third sheet), then the flames
            for (int pass = 0; pass < 2; pass++)
            {
                glUniform1i(L("uMode"), pass == 0 ? 1 : 0);
                for (int i = 0; i < _flames.Count; i++)
                {
                    if (pass == 0) glDrawArrays(GL_TRIANGLES, i * 18, 6);
                    else glDrawArrays(GL_TRIANGLES, i * 18 + 6, 12);
                }
            }
            glDisable(GL_BLEND); glDepthMask(1); glBindVertexArray(0);
        }
        // a surface of revolution round `axis` from `o`: radius r[i] at height h[i]; texture 0 wood, 1 iron, 2 coals
        void Lathe(float[] o, float[] axis, float[] unusedT, float[] r, float[] h, int sides, int tex, bool capTop)
        {
            float al = (float)Math.Sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
            float[] a = { axis[0] / al, axis[1] / al, axis[2] / al };
            float[] t0 = Math.Abs(a[1]) < 0.9f ? Cross(a, new[] { 0f, 1f, 0f }) : Cross(a, new[] { 1f, 0f, 0f }); Norm(t0);
            float[] t1 = Cross(a, t0);
            for (int i = 0; i + 1 < r.Length; i++)
                for (int k = 0; k < sides; k++)
                {
                    float[] p00 = Ring(o, a, t0, t1, r[i], h[i], k, sides), p01 = Ring(o, a, t0, t1, r[i], h[i], k + 1, sides);
                    float[] p10 = Ring(o, a, t0, t1, r[i + 1], h[i + 1], k, sides), p11 = Ring(o, a, t0, t1, r[i + 1], h[i + 1], k + 1, sides);
                    float u0 = (float)k / sides * 2, u1 = (float)(k + 1) / sides * 2, v0 = h[i] / 12f, v1 = h[i + 1] / 12f;
                    Quad(p00, p01, p11, p10, u0, v0, u1, v0, u1, v1, u0, v1, tex);
                }
            if (capTop) Disc(Along3(o, a, h[h.Length - 1]), a, r[r.Length - 1], sides, tex);
        }
        void Disc(float[] c, float[] axis, float rad, int sides, int tex)
        {
            float al = (float)Math.Sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
            float[] a = { axis[0] / al, axis[1] / al, axis[2] / al };
            float[] t0 = Math.Abs(a[1]) < 0.9f ? Cross(a, new[] { 0f, 1f, 0f }) : Cross(a, new[] { 1f, 0f, 0f }); Norm(t0);
            float[] t1 = Cross(a, t0);
            for (int k = 0; k < sides; k++)
            {
                float[] p0 = Ring(c, a, t0, t1, rad, 0, k, sides), p1 = Ring(c, a, t0, t1, rad, 0, k + 1, sides);
                double g0 = 2 * Math.PI * k / sides, g1 = 2 * Math.PI * (k + 1) / sides;
                Tri(c, p0, p1, 0.5f, 0.5f, 0.5f + 0.5f * (float)Math.Cos(g0), 0.5f + 0.5f * (float)Math.Sin(g0), 0.5f + 0.5f * (float)Math.Cos(g1), 0.5f + 0.5f * (float)Math.Sin(g1), tex);
            }
        }
        // a plate flat on the wall: `thick` out from it, `w` along it, `h` tall, centred on c
        void Box(float[] c, float nx, float nz, float thick, float w, float h, int tex)
        {
            float tx = -nz, tz = nx;      // along the wall
            Func<float, float, float, float[]> P = (a, b, d) => new[] { c[0] + tx * a + nx * d, c[1] + b, c[2] + tz * a + nz * d };
            float hw = w / 2, hh = h / 2;
            Quad(P(-hw, -hh, thick), P(hw, -hh, thick), P(hw, hh, thick), P(-hw, hh, thick), 0, 0, 1, 0, 1, 1.6f, 0, 1.6f, tex);
            Quad(P(-hw, -hh, 0), P(-hw, -hh, thick), P(-hw, hh, thick), P(-hw, hh, 0), 0, 0, 0.1f, 0, 0.1f, 1, 0, 1, tex);
            Quad(P(hw, -hh, 0), P(hw, -hh, thick), P(hw, hh, thick), P(hw, hh, 0), 0, 0, 0.1f, 0, 0.1f, 1, 0, 1, tex);
            Quad(P(-hw, hh, 0), P(hw, hh, 0), P(hw, hh, thick), P(-hw, hh, thick), 0, 0, 1, 0, 1, 0.1f, 0, 0.1f, tex);
            Quad(P(-hw, -hh, 0), P(hw, -hh, 0), P(hw, -hh, thick), P(-hw, -hh, thick), 0, 0, 1, 0, 1, 0.1f, 0, 0.1f, tex);
        }
        static float[] Cross(float[] a, float[] b) { return new[] { a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] }; }
        static void Norm(float[] v) { float l = (float)Math.Sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); if (l > 1e-9f) { v[0] /= l; v[1] /= l; v[2] /= l; } }
        static float[] Along3(float[] o, float[] a, float d) { return new[] { o[0] + a[0] * d, o[1] + a[1] * d, o[2] + a[2] * d }; }
        static float[] Ring(float[] o, float[] a, float[] t0, float[] t1, float r, float h, int k, int sides)
        {
            double g = 2 * Math.PI * k / sides; float c = (float)Math.Cos(g) * r, sn = (float)Math.Sin(g) * r;
            return new[] { o[0] + a[0] * h + t0[0] * c + t1[0] * sn, o[1] + a[1] * h + t0[1] * c + t1[1] * sn, o[2] + a[2] * h + t0[2] * c + t1[2] * sn };
        }
        void Quad(float[] a, float[] b, float[] c, float[] d, float ua, float va, float ub, float vb, float uc, float vc, float ud, float vd, int tex)
        { Tri(a, b, c, ua, va, ub, vb, uc, vc, tex); Tri(a, c, d, ua, va, uc, vc, ud, vd, tex); }
        // both sides (an open cup is seen from inside; and no winding to get wrong)
        void Tri(float[] a, float[] b, float[] c, float ua, float va, float ub, float vb, float uc, float vc, int tex)
        {
            for (int side = 0; side < 2; side++)
            {
                int n0 = _pV.Count / 3;
                foreach (var p in side == 0 ? new[] { a, b, c } : new[] { a, c, b }) { _pV.Add(p[0]); _pV.Add(p[1]); _pV.Add(p[2]); }
                if (side == 0) { _pUV.Add(ua); _pUV.Add(va); _pUV.Add(ub); _pUV.Add(vb); _pUV.Add(uc); _pUV.Add(vc); }
                else { _pUV.Add(ua); _pUV.Add(va); _pUV.Add(uc); _pUV.Add(vc); _pUV.Add(ub); _pUV.Add(vb); }
                _pT.Add(n0); _pT.Add(n0 + 1); _pT.Add(n0 + 2); _pTri.Add(tex);
            }
        }
        // the props' own textures, made once: weathered wood (grain along v), dark wrought iron, charred coals
        void EnsurePropTextures()
        {
            if (_pTex != null) return;
            const int N = 256; _pTex = new Raster.Tex[3];
            for (int k = 0; k < 3; k++)
            {
                var idx = new byte[N * N]; for (int i = 0; i < idx.Length; i++) idx[i] = 1;
                var px = new int[N * N];
                for (int y = 0; y < N; y++) for (int x = 0; x < N; x++)
                {
                    double u = x / (double)N, v = y / (double)N, r, g, b;
                    if (k == 0)
                    {
                        // wood: streaks along v (the stake's length), a few darker knots and cracks
                        double grain = Fbm2(u * 24, v * 2.5, 3) * 0.6 + 0.4 * Math.Sin((u * 40 + Fbm2(u * 6, v * 6, 2) * 3) * Math.PI);
                        double crack = Math.Pow(Math.Max(0, 1 - Math.Abs(Fbm2(u * 9 + 3, v * 1.2, 2) - 0.5) * 18), 3);
                        double t = 0.55 + 0.25 * grain - 0.35 * crack;
                        r = 76 * t + 16; g = 60 * t + 12; b = 44 * t + 9;          // (weathered grey-brown: the torchlight warms it)
                    }
                    else if (k == 1)
                    {
                        // iron: near-black, hammered, a little rust
                        double n = Fbm2(u * 16, v * 16, 4), rust = Math.Max(0, Fbm2(u * 5 + 7, v * 5 + 2, 3) - 0.55) * 2.2;
                        double t = 0.32 + 0.22 * n;
                        r = 70 * t + 60 * rust; g = 66 * t + 28 * rust; b = 62 * t + 10 * rust;
                    }
                    else
                    {
                        // coals: black, cracked, faint ember-orange in the cracks
                        double n = Fbm2(u * 10, v * 10, 4), crack = Math.Pow(Math.Max(0, 1 - Math.Abs(n - 0.5) * 9), 4);
                        r = 18 + 26 * n + 150 * crack; g = 14 + 18 * n + 50 * crack; b = 12 + 12 * n + 10 * crack;
                    }
                    px[y * N + x] = ((int)Math.Min(255, r) << 16) | ((int)Math.Min(255, g) << 8) | (int)Math.Min(255, b);
                }
                var tx = new Raster.Tex(idx, N, N); tx.SetRgb(px, N, N); tx.NoCast = k != 0; _pTex[k] = tx;      // (only the wooden stake casts a shadow: Josh, MINEMAZE/4)
                // their materials (rooms\_materials.json's wood and iron; the coals dull)
                if (k == 0) { tx.Material = "wood"; tx.Shine = 0.03f; tx.Gloss = 8f; tx.ShineVary = 0.8f; tx.Wet = 0.5f; }
                else if (k == 1) { tx.Material = "iron"; tx.Shine = 0.22f; tx.Gloss = 26f; tx.Metal = 0.5f; tx.ShineVary = 1.5f; tx.Wet = 0.3f; tx.Relief = 0.4f; }
                else tx.Material = "matte";
            }
        }
        // value noise, tiled every 64 cells (seamless as the texture repeats at whole frequencies)
        static double Hash2(int x, int y) { uint h = (uint)(x * 374761393 + y * 668265263); h = (h ^ (h >> 13)) * 1274126177u; return ((h ^ (h >> 16)) & 0xFFFFFF) / 16777216.0; }
        static double Noise2(double x, double y)
        {
            int ix = (int)Math.Floor(x), iy = (int)Math.Floor(y); double fx = x - ix, fy = y - iy;
            fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
            double a = Hash2(ix, iy), b = Hash2(ix + 1, iy), c = Hash2(ix, iy + 1), d = Hash2(ix + 1, iy + 1);
            return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy;
        }
        static double Fbm2(double x, double y, int oct) { double s = 0, a = 0.5, n = 0; for (int i = 0; i < oct; i++) { s += Noise2(x, y) * a; n += a; x *= 2.03; y *= 2.03; a *= 0.5; } return s / n; }
        // the room's geometry with the props after it (Draw takes this instead when there are props)
        float[] _mV, _mUV; int[] _mT, _mTri; Raster.Tex[] _mTex; Raster.Tex[] _mTexKey;
        void MergeProps(ref float[] vx, ref float[] uv, ref int[] idx, ref int[] triTex, ref Raster.Tex[] texes)
        {
            int pv = _pV.Count, pt = _pT.Count, nv = vx.Length / 3, nTex = texes.Length;
            if (_mV == null || _mV.Length != vx.Length + pv) _mV = new float[vx.Length + pv];
            Array.Copy(vx, _mV, vx.Length); _pV.CopyTo(_mV, vx.Length);
            if (_mUV == null || _mUV.Length != uv.Length + _pUV.Count) _mUV = new float[uv.Length + _pUV.Count];
            Array.Copy(uv, _mUV, uv.Length); _pUV.CopyTo(_mUV, uv.Length);
            if (_mT == null || _mT.Length != idx.Length + pt)
            {
                _mT = new int[idx.Length + pt]; _mTri = new int[(idx.Length + pt) / 3];
            }
            Array.Copy(idx, _mT, idx.Length); for (int i = 0; i < pt; i++) _mT[idx.Length + i] = _pT[i] + nv;
            int rt = idx.Length / 3; Array.Copy(triTex, _mTri, Math.Min(triTex.Length, rt)); for (int i = 0; i < _pTri.Count; i++) _mTri[rt + i] = _pTri[i] + nTex;
            if (!ReferenceEquals(_mTexKey, texes) || _mTex == null || _mTex.Length != nTex + _pTex.Length)
            { _mTex = new Raster.Tex[nTex + _pTex.Length]; Array.Copy(texes, _mTex, nTex); Array.Copy(_pTex, 0, _mTex, nTex, _pTex.Length); _mTexKey = texes; }
            vx = _mV; uv = _mUV; idx = _mT; triTex = _mTri; texes = _mTex;
        }
        // ---- THE PAINTED DARKNESS (Josh, 2026-10-08, Room Review CORICORI/5-6: "match the dark black areas in this corridor
        // with a layer of black volumetric fog ... to emulate the lighting the original developers tried to achieve with the
        // texture art") -------------------------------------------------------------------------------------------------
        // The artists painted the lighting into the textures (a corridor fading to black). Made into the volumetric fog: the
        // room's surfaces are sampled -- every floor, wall and ceiling, at their textures' own colours -- into a floor plan of
        // how bright the art is there, smoothed, and where it is darker than the room's well-lit parts the fog is that much
        // thicker black (marched with the rest of the fog; the flashlight thins it as it thins the fog).
        public bool PaintOn; public float PaintDensity = 0.02f, PaintMax = 0.85f;
        uint _paintTex; float _paintX0, _paintZ0, _paintSX, _paintSZ; public int PaintCells; public string PaintNote = "";
        /// <summary>Build the floor plan from the room as it will be drawn (its textures' colours loaded): `cell` units a cell,
        /// smoothed over `smooth` units; `gamma` shapes how fast it darkens below the room's bright level.</summary>
        public void BuildPaintField(float[] vx, float[] uv, int[] idx, int[] triTex, Raster.Tex[] texes, bool flipV, float cell, float smooth, float gamma, byte[] pal)
        {
            PaintOn = false; PaintCells = 0;
            if (vx == null || idx == null || idx.Length < 3) return;
            cell = Math.Max(2f, cell);
            float x0 = float.MaxValue, z0 = float.MaxValue, x1 = float.MinValue, z1 = float.MinValue;
            for (int i = 0; i < vx.Length; i += 3) { float x = vx[i], z = vx[i + 2]; if (x < x0) x0 = x; if (x > x1) x1 = x; if (z < z0) z0 = z; if (z > z1) z1 = z; }
            float pad = smooth * 2; x0 -= pad; z0 -= pad; x1 += pad; z1 += pad;
            int nx = Math.Max(4, Math.Min(1024, (int)Math.Ceiling((x1 - x0) / cell))), nz = Math.Max(4, Math.Min(1024, (int)Math.Ceiling((z1 - z0) / cell)));
            float cx = (x1 - x0) / nx, cz = (z1 - z0) / nz;
            var sum = new double[nx * nz]; var cnt = new double[nx * nz];
            // each triangle: sample points spread over it (as many as its area wants), the texture's colour at each, from a
            // small copy of the texture (the painted light, not the stones' detail)
            uint seed = 2463534242u;
            for (int t = 0; t + 2 < idx.Length; t += 3)
            {
                int ti = triTex != null && t / 3 < triTex.Length ? triTex[t / 3] : -1;
                if (ti < 0 || texes == null || ti >= texes.Length || texes[ti] == null) continue;
                // FROM THE ORIGINAL ART (Josh, round 10: "if I were to render the textures without the dark lighting ... I want to
                // maintain our volumetric darkness"): with the game's palette given, the colours are the game's own pixels (Idx)
                // -- the darkness map stays the original vision whatever replacement textures are loaded over them
                var tx = texes[ti]; bool orig = pal != null && pal.Length >= 768 && tx.Idx != null;
                if (!orig && (tx.Rgb == null || tx.Rgb.Length == 0)) continue;
                int lv = 0; if (!orig) while (lv + 1 < tx.Rgb.Length && tx.Rgb[lv].W > 64) lv++;
                var L = orig ? null : tx.Rgb[lv];
                int a = idx[t], b = idx[t + 1], c = idx[t + 2];
                float ax = vx[a * 3], ay = vx[a * 3 + 1], az = vx[a * 3 + 2], bx = vx[b * 3], by = vx[b * 3 + 1], bz = vx[b * 3 + 2], qx = vx[c * 3], qy = vx[c * 3 + 1], qz = vx[c * 3 + 2];
                float ux = bx - ax, uy = by - ay, uz = bz - az, wx = qx - ax, wy = qy - ay, wz = qz - az;
                float crx = uy * wz - uz * wy, cry = uz * wx - ux * wz, crz = ux * wy - uy * wx;
                double area = 0.5 * Math.Sqrt(crx * crx + cry * cry + crz * crz);
                int n = (int)Math.Min(4000, Math.Max(1, area / (cell * cell * 0.25)));
                for (int k = 0; k < n; k++)
                {
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; float r1 = (seed & 0xFFFFFF) / 16777216f;
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; float r2 = (seed & 0xFFFFFF) / 16777216f;
                    if (r1 + r2 > 1) { r1 = 1 - r1; r2 = 1 - r2; }
                    float px = ax + ux * r1 + wx * r2, pz = az + uz * r1 + wz * r2;
                    float su = uv[a * 2] + (uv[b * 2] - uv[a * 2]) * r1 + (uv[c * 2] - uv[a * 2]) * r2;
                    float sv = uv[a * 2 + 1] + (uv[b * 2 + 1] - uv[a * 2 + 1]) * r1 + (uv[c * 2 + 1] - uv[a * 2 + 1]) * r2;
                    if (flipV) sv = 1 - sv;
                    su -= (float)Math.Floor(su); sv -= (float)Math.Floor(sv);
                    // a hole in the texture (palette 0 in the original) is not surface
                    if (tx.Idx != null && tx.Idx[Math.Min(tx.H - 1, (int)(sv * tx.H)) * tx.W + Math.Min(tx.W - 1, (int)(su * tx.W))] == 0) continue;
                    double lum;
                    if (orig) { int pi = tx.Idx[Math.Min(tx.H - 1, (int)(sv * tx.H)) * tx.W + Math.Min(tx.W - 1, (int)(su * tx.W))] * 3; lum = 0.30 * pal[pi] + 0.59 * pal[pi + 1] + 0.11 * pal[pi + 2]; }
                    else { int pxl = L.Px[Math.Min(L.H - 1, (int)(sv * L.H)) * L.W + Math.Min(L.W - 1, (int)(su * L.W))]; lum = 0.30 * ((pxl >> 16) & 255) + 0.59 * ((pxl >> 8) & 255) + 0.11 * (pxl & 255); }
                    int gx = (int)((px - x0) / cx), gz = (int)((pz - z0) / cz);
                    if (gx < 0 || gz < 0 || gx >= nx || gz >= nz) continue;
                    sum[gz * nx + gx] += lum; cnt[gz * nx + gx] += 1;
                }
            }
            // smoothed (a gaussian, two passes; brightness and coverage alike, so empty cells borrow from their neighbours)
            double sig = Math.Max(0.5, smooth / cell); int rad = (int)Math.Ceiling(sig * 2.5); var kw = new double[2 * rad + 1];
            for (int i = -rad; i <= rad; i++) kw[i + rad] = Math.Exp(-0.5 * i * i / (sig * sig));
            Func<double[], bool, double[]> Blur = (src, alongX) =>
            {
                var dst = new double[src.Length];
                for (int z = 0; z < nz; z++) for (int x = 0; x < nx; x++)
                {
                    double s = 0; for (int i = -rad; i <= rad; i++) { int xx = alongX ? x + i : x, zz = alongX ? z : z + i; if (xx < 0 || zz < 0 || xx >= nx || zz >= nz) continue; s += src[zz * nx + xx] * kw[i + rad]; }
                    dst[z * nx + x] = s;
                }
                return dst;
            };
            var bs = Blur(Blur(sum, true), false); var bc = Blur(Blur(cnt, true), false);
            // the room's bright level: the 85th percentile of the cells that have surface
            var lums = new List<double>(); var lumAt = new double[nx * nz];
            double cmax = 0; for (int i = 0; i < bc.Length; i++) if (bc[i] > cmax) cmax = bc[i];
            for (int i = 0; i < bc.Length; i++) { lumAt[i] = -1; if (bc[i] > cmax * 0.02) { lumAt[i] = bs[i] / bc[i]; lums.Add(lumAt[i]); } }
            if (lums.Count < 4) { PaintNote = "no surfaces sampled"; return; }
            lums.Sort(); double bright = Math.Max(8, lums[(int)(lums.Count * 0.85)]), dark = lums[(int)(lums.Count * 0.05)];
            var px8 = new byte[nx * nz]; int dk = 0;
            for (int i = 0; i < px8.Length; i++)
            {
                if (lumAt[i] < 0) continue;
                double d = Math.Max(0, Math.Min(1, 1 - lumAt[i] / bright)); d = Math.Pow(d, Math.Max(0.2, gamma));
                px8[i] = (byte)Math.Round(d * 255); if (d > 0.5) dk++;
            }
            if (_paintTex == 0) { var ids = new uint[1]; glGenTextures(1, ids); _paintTex = ids[0]; }
            glBindTexture(GL_TEXTURE_2D, _paintTex);
            glTexImage2DB(GL_TEXTURE_2D, 0, (int)GL_R8, nx, nz, 0, GL_RED, GL_UNSIGNED_BYTE, px8);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_CLAMP_TO_EDGE);
            _paintX0 = x0; _paintZ0 = z0; _paintSX = 1f / (x1 - x0); _paintSZ = 1f / (z1 - z0);
            PaintCells = nx * nz; PaintOn = true; _paintPx = px8; _paintW = nx; _paintH = nz;
            _lum = new float[lumAt.Length]; for (int i = 0; i < lumAt.Length; i++) _lum[i] = (float)lumAt[i]; _lumX0 = x0; _lumZ0 = z0; _lumCX = cx; _lumCZ = cz; _lumBright = (float)bright;
            PaintNote = string.Format("{0}x{1} cells of {2:N0} units, the art's bright level {3:N0} (darkest {4:N0}), {5:P0} of the room's floor plan painted darker than half", nx, nz, cx, bright, dark, (double)dk / Math.Max(1, lums.Count));
        }
        byte[] _paintPx; int _paintW, _paintH;

        // ---- BOUNCED LIGHT (2026-10-09, Josh: "Bounced light (global illumination), pre-calculated per room") -------------
        // GiBake's probe grid on the card: one RGBA16F 3D texture, NX x NY x 4*NZ -- the red, green and blue harmonics, then
        // each probe's validity -- read texel by texel in FS_MAIN's giAt (its own filtering, so probes in walls drop out).
        const int UNIT_GI = 15; const uint GL_TEXTURE_3D = 0x806F, GL_TEXTURE_WRAP_R = 0x8072;
        int mGiOn = -2, mGi, mGiBox, mGiN, mGiK, mGiAmb;
        uint _giTex; float _giX0, _giY0, _giZ0, _giSpacing = 1f; int _giNX, _giNY, _giNZ;
        /// <summary>Drawn with the room's bounced light (when one has been given: SetGi).</summary>
        public bool GiOn;
        /// <summary>The bounced light's strength (room setting gi.strength); GiFlicker: times the torches' flicker now.</summary>
        public float GiStrength = 1f, GiFlicker = 1f;
        /// <summary>The room's own flat level while bounced light is on, as a share of it (room setting gi.ambient).</summary>
        public float GiAmbient = 0.6f;
        public string GiNote = "";
        /// <summary>Put a finished bake on the card (on the drawing thread). Null: none (GiOn off).</summary>
        public bool SetGi(GiBake b)
        {
            GiOn = false;
            if (b == null || b.SH == null || b.Valid == null) return false;
            if (glTexImage3D == null) { GiNote = "the graphics driver has no 3D textures"; return false; }
            int nx = b.NX, ny = b.NY, nz = b.NZ, np = nx * ny * nz;
            var px = new float[np * 4 * 4];
            for (int p = 0; p < np; p++)
            {
                for (int c = 0; c < 3; c++)
                {
                    int dst = ((c * np) + p) * 4, src = p * 12 + c * 4;      // slab c: (z + c*nz) -- p already runs x fastest, then y, then z
                    px[dst] = b.SH[src]; px[dst + 1] = b.SH[src + 1]; px[dst + 2] = b.SH[src + 2]; px[dst + 3] = b.SH[src + 3];
                }
                px[((3 * np) + p) * 4] = b.Valid[p];
            }
            if (_giTex == 0) { var ids = new uint[1]; glGenTextures(1, ids); _giTex = ids[0]; }
            glActiveTexture(GL_TEXTURE0 + (uint)UNIT_GI);
            glBindTexture(GL_TEXTURE_3D, _giTex);
            glTexImage3D(GL_TEXTURE_3D, 0, (int)GL_RGBA16F, nx, ny, nz * 4, 0, GL_RGBA, GL_FLOAT, px);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAX_LEVEL, 0);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, (int)GL_CLAMP_TO_EDGE);
            glActiveTexture(GL_TEXTURE0);
            Check("bounced light upload");
            _giX0 = b.X0; _giY0 = b.Y0; _giZ0 = b.Z0; _giSpacing = b.Spacing; _giNX = nx; _giNY = ny; _giNZ = nz;
            GiOn = true; GiNote = b.Note;
            return true;
        }
        public void ClearGi() { GiOn = false; GiNote = ""; }
        /// <summary>A texture's holes changed (Raster.Tex.CutHoles / RestoreHoles): its hole mask goes up again (on the drawing
        /// thread). Not uploaded yet: nothing to do -- it goes up with the new holes when first drawn.</summary>
        public bool RefreshMask(Raster.Tex t)
        {
            GTex g; if (t == null || !_tex.TryGetValue(t, out g) || g.Mask == 0) return false;
            glBindTexture(GL_TEXTURE_2D, g.Mask);
            glTexImage2DB(GL_TEXTURE_2D, 0, (int)GL_RG8, t.W, t.H, 0, GL_RG, GL_UNSIGNED_BYTE, MaskBytes(t));
            g.ArtSrc = t.ArtLight; g.IdxSrc = t.Idx;
            return true;
        }
        /// <summary>The hole mask as the card holds it: the palette index, then the light from the artwork (255 = none).</summary>
        static byte[] MaskBytes(Raster.Tex t)
        {
            int n = t.W * t.H; var b = new byte[n * 2]; var a = t.ArtLight != null && t.ArtLight.Length == n ? t.ArtLight : null;
            for (int i = 0; i < n; i++) { b[i * 2] = t.Idx[i]; b[i * 2 + 1] = a != null ? a[i] : (byte)255; }
            return b;
        }

        // ---- LIGHT FROM THE ARTWORK (Josh, 2026-10-09, Room Review MINEHEAD/2-4: "we need hard shading from the panel above
        // ... see original artwork for reference"; "only the corners and edges use the very dark lighting") -------------------
        // The original artists painted each surface's light and shade into its texture. Read back out of the ORIGINAL pixels
        // (whatever replacement art is loaded), per texel: brightness, small bright marks taken out (painted light grids,
        // glints: an opening), small dark ones too (cracks, joints: a closing), smoothed a little -- so the broad light and
        // shade stays, with its hard edges. Against the room's well-lit level (a high percentile), shaped by gamma, never below
        // floor. It shades the room's level and the bounce on that surface; the placed lights and the flashlight are not.
        public bool ArtOn; public int RoomTint = 0xFFFFFF, PaintColor = 0; public string ArtNote = "";
        /// <summary>The mean colour of the art's well-lit texels (0xRRGGBB), for a room tint or fog colour that matches it.</summary>
        public int ArtBrightColor, ArtTint = 0xFFFFFF;
        public int BuildArtLight(Raster.Tex[] texes, byte[] pal, float floor, float gamma, int open, int close, int blur, float percentile, string[] exclude)
        {
            ArtOn = false; ArtNote = ""; ArtBrightColor = 0; ArtTint = 0xFFFFFF;
            if (texes == null || pal == null || pal.Length < 768) { ArtNote = "no palette"; return 0; }
            var skip = new HashSet<string>(exclude ?? new string[0], StringComparer.OrdinalIgnoreCase);
            var maps = new Dictionary<Raster.Tex, float[]>(); var all = new List<float>();
            foreach (var t in texes)
            {
                if (t == null) continue;
                t.ArtLight = null;
                if (t.Moves || t.Idx == null || (t.Leaf != null && skip.Contains(t.Leaf)) || maps.ContainsKey(t)) continue;
                var src = t.IdxOrig ?? t.Idx; int w = t.W, h = t.H, n = w * h;
                var L = new float[n]; var has = new bool[n];
                for (int i = 0; i < n; i++) { if (src[i] == 0) continue; int k = src[i] * 3; L[i] = (float)(0.30 * pal[k] + 0.59 * pal[k + 1] + 0.11 * pal[k + 2]); has[i] = true; }
                // opening: small bright marks out; closing: small dark ones out (square, separable; holes take no part)
                if (open > 0) { L = Morph(L, has, w, h, open, false); L = Morph(L, has, w, h, open, true); }
                if (close > 0) { L = Morph(L, has, w, h, close, true); L = Morph(L, has, w, h, close, false); }
                if (blur > 0) L = BoxBlur(BoxBlur(L, has, w, h, blur), has, w, h, blur);
                maps[t] = L;
                for (int i = 0; i < n; i++) if (has[i]) all.Add(L[i]);
            }
            if (all.Count < 16) { ArtNote = "no art to read"; return 0; }
            all.Sort(); float bright = Math.Max(8f, all[Math.Min(all.Count - 1, (int)(all.Count * Math.Max(0.5f, Math.Min(0.99f, percentile))))]);
            // the well-lit texels' own colour (from the unfiltered originals)
            double sr = 0, sg = 0, sb = 0; long sn = 0;
            foreach (var kv in maps)
            {
                var t = kv.Key; var src = t.IdxOrig ?? t.Idx; var L = kv.Value; int n = t.W * t.H; var a = new byte[n];
                for (int i = 0; i < n; i++)
                {
                    double m = Math.Max(0.0, Math.Min(1.0, L[i] / bright));
                    a[i] = (byte)Math.Round(255 * (floor + (1 - floor) * Math.Pow(m, Math.Max(0.1, gamma))));
                    if (src[i] != 0 && L[i] >= bright) { int k = src[i] * 3; sr += pal[k]; sg += pal[k + 1]; sb += pal[k + 2]; sn++; }
                }
                t.ArtLight = a;
            }
            if (sn > 0)
            {
                ArtBrightColor = ((int)(sr / sn) << 16) | ((int)(sg / sn) << 8) | (int)(sb / sn);
                double mx = Math.Max(1.0, Math.Max(sr, Math.Max(sg, sb)) / sn);      // (as a tint: its hue, the brightest channel at full)
                ArtTint = ((int)Math.Round(255 * sr / sn / mx) << 16) | ((int)Math.Round(255 * sg / sn / mx) << 8) | (int)Math.Round(255 * sb / sn / mx);
            }
            ArtOn = maps.Count > 0;
            ArtNote = string.Format("{0} textures, well lit at {1:N0}/255, its colour #{2:X6}", maps.Count, bright, ArtBrightColor);
            return maps.Count;
        }
        /// <summary>The light from the artwork taken off these textures (a room without it).</summary>
        public void ClearArtLight(Raster.Tex[] texes) { ArtOn = false; ArtNote = ""; if (texes != null) foreach (var t in texes) if (t != null) t.ArtLight = null; }
        // a square min (dilate = false) or max (dilate = true) of radius r, rows then columns; texels without art are skipped
        static float[] Morph(float[] s, bool[] has, int w, int h, int r, bool dilate)
        {
            var a = new float[s.Length]; var b = new float[s.Length];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            {
                float v = dilate ? float.MinValue : float.MaxValue; bool any = false;
                for (int d = -r; d <= r; d++) { int xx = x + d; if (xx < 0 || xx >= w || !has[y * w + xx]) continue; float q = s[y * w + xx]; v = dilate ? Math.Max(v, q) : Math.Min(v, q); any = true; }
                a[y * w + x] = any ? v : s[y * w + x];
            }
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            {
                float v = dilate ? float.MinValue : float.MaxValue; bool any = false;
                for (int d = -r; d <= r; d++) { int yy = y + d; if (yy < 0 || yy >= h || !has[yy * w + x]) continue; float q = a[yy * w + x]; v = dilate ? Math.Max(v, q) : Math.Min(v, q); any = true; }
                b[y * w + x] = any ? v : a[y * w + x];
            }
            return b;
        }
        // a box blur of radius r, rows then columns, over the texels with art only (the holes take their neighbours' value)
        static float[] BoxBlur(float[] s, bool[] has, int w, int h, int r)
        {
            var a = new float[s.Length]; var b = new float[s.Length];
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            {
                double v = 0; int c = 0;
                for (int d = -r; d <= r; d++) { int xx = x + d; if (xx < 0 || xx >= w || !has[y * w + xx]) continue; v += s[y * w + xx]; c++; }
                a[y * w + x] = c > 0 ? (float)(v / c) : s[y * w + x];
            }
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
            {
                double v = 0; int c = 0;
                for (int d = -r; d <= r; d++) { int yy = y + d; if (yy < 0 || yy >= h || !has[yy * w + x]) continue; v += a[yy * w + x]; c++; }
                b[y * w + x] = c > 0 ? (float)(v / c) : a[y * w + x];
            }
            return b;
        }
        // the smoothed brightness of the art behind the map (-1 = no surface there), for finding where the original painted
        // its light (Josh, round 12: "add real light sources throughout in the bright areas")
        float[] _lum; float _lumX0, _lumZ0, _lumCX, _lumCZ, _lumBright;
        public float[] PaintLum(out int nx, out int nz, out float x0, out float z0, out float cellX, out float cellZ, out float bright)
        { nx = _paintW; nz = _paintH; x0 = _lumX0; z0 = _lumZ0; cellX = _lumCX; cellZ = _lumCZ; bright = _lumBright; return _lum; }
        /// <summary>The floor plan as a picture (white = dark painted), for checking.</summary>
        public void SavePaintField(string path)
        {
            if (_paintPx == null) return;
            using (var b = new System.Drawing.Bitmap(_paintW, _paintH))
            {
                for (int z = 0; z < _paintH; z++) for (int x = 0; x < _paintW; x++) { int v = _paintPx[z * _paintW + x]; b.SetPixel(x, _paintH - 1 - z, System.Drawing.Color.FromArgb(v, v, v)); }
                b.Save(path);
            }
        }
        // ---- HOLOGRAMS (Josh, 2026-10-08, Room Review CORICORI/4: "Add the polygonal chalice from the intro here") -------
        // The visor boot's ARTIFACT TRACE -- the chalice as a teal vector wireframe (BootHd.DrawChalice: the same lathe
        // profile, 14 meridians, its rings) -- standing in the room: revolving, bobbing a little, a scan ring passing down it.
        // Lines of a constant width on the screen (each segment a quad turned to face the eye, no geometry shader), hidden
        // behind the room (depth test, no depth write), added to the picture: a wide faint halo, then a crisp core whose
        // near side flares, as the intro draws it.
        class Holo { public float X, Y, Z, H, Spin, Glow, Hover, Bob; public int Col, Flare; public bool Scan; }
        readonly List<Holo> _holos = new List<Holo>();
        public void ClearHolos() { _holos.Clear(); }
        /// <summary>A chalice hologram: its foot's centre (x, y = the floor, z), height (units), turn (radians a second),
        /// line colour and flare colour (0xRRGGBB), brightness, how far it floats above y, how far it bobs, a scan ring.</summary>
        public void AddHoloChalice(float x, float y, float z, float height, float spin, int colour, int flare, float glow, float hover, float bob, bool scan)
        { _holos.Add(new Holo { X = x, Y = y, Z = z, H = Math.Max(1f, height), Spin = spin, Col = colour, Flare = flare, Glow = glow, Hover = hover, Bob = bob, Scan = scan }); }
        public int LastHoloSegs; public float HoloHalo = 5f, HoloCore = 1.25f;    // line half-widths, pixels at 1200 rows
        static readonly double[] HCupR = { 0.40, 0.38, 0.15, 0.075, 0.06, 0.12, 0.06, 0.07, 0.22, 0.35, 0.43, 0.46, 0.45 };
        static readonly double[] HCupY = { 0.00, 0.03, 0.07, 0.14, 0.30, 0.38, 0.45, 0.52, 0.58, 0.68, 0.82, 0.94, 1.00 };
        static readonly int[] HCupRings = { 0, 2, 5, 7, 9, 11, 12 };
        const int HSTRIDE = 17;     // a vertex: end A, end B, the hologram's axis point, (end, side), line colour, flare colour
        uint _pHolo, _hVao, _hVbo; float[] _hVerts = new float[0];
        const string VS_HOLO = @"#version 400 core
layout(location = 0) in vec3 aA; layout(location = 1) in vec3 aB; layout(location = 2) in vec3 aC;
layout(location = 3) in vec2 aES; layout(location = 4) in vec3 aCol; layout(location = 5) in vec3 aFlare;
uniform mat4 uView; uniform vec2 uF; uniform float uNear, uOffY; uniform vec2 uHalf; uniform float uWidth; uniform vec3 uEye;
out vec3 vCol; out vec3 vFlare; out float vSide; out float vNear;
vec4 clipOf(vec3 w) { vec4 p = uView * vec4(w, 1.0); return vec4(p.x * uF.x, -p.y * uF.y + uOffY * p.z, uNear, p.z); }
void main() {
    vec4 a = clipOf(aA), b = clipOf(aB);
    vCol = aCol; vFlare = aFlare; vSide = aES.y; vNear = 0.0;
    if (a.w < 1.0 || b.w < 1.0) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }      // (an end behind the eye: left out)
    vec2 sa = a.xy / a.w * uHalf, sb = b.xy / b.w * uHalf, d = sb - sa; float l = length(d);
    vec2 dn = l > 1e-4 ? d / l : vec2(1.0, 0.0), n = vec2(-dn.y, dn.x);
    vec4 c = aES.x < 0.5 ? a : b;
    vec2 s = c.xy / c.w * uHalf + n * (aES.y * uWidth) + dn * ((aES.x < 0.5 ? -0.5 : 0.5) * uWidth);
    gl_Position = vec4(s / uHalf * c.w, c.z, c.w);
    // the side of the chalice toward the eye is the bright one (the intro's near/far)
    vec3 mid = (aA + aB) * 0.5, r = mid - aC, t = uEye - mid; r.y = 0.0; t.y = 0.0;
    vNear = (dot(r, r) > 1e-6 && dot(t, t) > 1e-6) ? 0.5 + 0.5 * dot(normalize(r), normalize(t)) : 1.0;
}";
        const string FS_HOLO = @"#version 400 core
in vec3 vCol; in vec3 vFlare; in float vSide; in float vNear;
uniform float uAlpha; uniform int uCore;
out vec4 oColor;
void main() {
    float e = abs(vSide);
    float a = uCore != 0 ? 1.0 - smoothstep(0.45, 1.0, e) : (1.0 - e) * (1.0 - e);
    vec3 c = uCore != 0 ? mix(vCol, vFlare, smoothstep(0.78, 0.95, vNear)) : vCol;
    oColor = vec4(c * (a * uAlpha * (0.25 + 0.75 * vNear)), 0.0);
}";
        int BuildHolos()
        {
            int segs = 0; foreach (var h in _holos) segs += 14 * (HCupR.Length - 1) + HCupRings.Length * 32 + (h.Scan ? 32 : 0);
            if (_hVerts.Length < segs * 6 * HSTRIDE) _hVerts = new float[segs * 6 * HSTRIDE];
            int k = 0; float t = Time;
            foreach (var h in _holos)
            {
                double phi = t * h.Spin; float baseY = h.Y + h.Hover + h.Bob * (float)Math.Sin(t * 1.3);
                float cr = ((h.Col >> 16) & 255) / 255f * h.Glow, cg = ((h.Col >> 8) & 255) / 255f * h.Glow, cb = (h.Col & 255) / 255f * h.Glow;
                float fr = ((h.Flare >> 16) & 255) / 255f * h.Glow, fg = ((h.Flare >> 8) & 255) / 255f * h.Glow, fb = (h.Flare & 255) / 255f * h.Glow;
                Func<double, double, double, float[]> P = (r, th, y) => new[] { h.X + (float)(r * h.H * Math.Cos(th + phi)), baseY + (float)(y * h.H), h.Z + (float)(r * h.H * Math.Sin(th + phi)) };
                float cy = baseY + h.H * 0.5f;
                for (int j = 0; j < 14; j++)
                {
                    double th = 2 * Math.PI * j / 14;
                    for (int i = 0; i + 1 < HCupR.Length; i++) Seg(ref k, P(HCupR[i], th, HCupY[i]), P(HCupR[i + 1], th, HCupY[i + 1]), h.X, cy, h.Z, cr, cg, cb, fr, fg, fb);
                }
                foreach (int ri in HCupRings)
                    for (int q = 0; q < 32; q++) Seg(ref k, P(HCupR[ri], 2 * Math.PI * q / 32, HCupY[ri]), P(HCupR[ri], 2 * Math.PI * (q + 1) / 32, HCupY[ri]), h.X, cy, h.Z, cr, cg, cb, fr, fg, fb);
                if (h.Scan)
                {
                    // the scan passing down over it every 2.4 s, a ring a little wider than the chalice there, flare-bright
                    double sp = 1 - (t % 2.4) / 2.4; int i0 = 0; while (i0 + 2 < HCupY.Length && HCupY[i0 + 1] < sp) i0++;
                    double u = Math.Max(0, Math.Min(1, (sp - HCupY[i0]) / (HCupY[i0 + 1] - HCupY[i0]))), rr = (HCupR[i0] + (HCupR[i0 + 1] - HCupR[i0]) * u) * 1.25;
                    for (int q = 0; q < 32; q++) Seg(ref k, P(rr, 2 * Math.PI * q / 32, sp), P(rr, 2 * Math.PI * (q + 1) / 32, sp), h.X, cy, h.Z, fr * 0.7f, fg * 0.7f, fb * 0.7f, fr, fg, fb);
                }
            }
            return k;
        }
        void Seg(ref int k, float[] a, float[] b, float cx, float cy, float cz, float cr, float cg, float cb, float fr, float fg, float fb)
        {
            // two triangles: (A,-1) (B,-1) (B,+1)  (A,-1) (B,+1) (A,+1)
            for (int v = 0; v < 6; v++)
            {
                float end = (v == 1 || v == 2 || v == 4) ? 1f : 0f, side = (v == 2 || v == 4 || v == 5) ? 1f : -1f;
                int o = k * HSTRIDE; var f = _hVerts;
                f[o] = a[0]; f[o + 1] = a[1]; f[o + 2] = a[2]; f[o + 3] = b[0]; f[o + 4] = b[1]; f[o + 5] = b[2];
                f[o + 6] = cx; f[o + 7] = cy; f[o + 8] = cz; f[o + 9] = end; f[o + 10] = side;
                f[o + 11] = cr; f[o + 12] = cg; f[o + 13] = cb; f[o + 14] = fr; f[o + 15] = fg; f[o + 16] = fb;
                k++;
            }
        }
        void DrawHolos()
        {
            int n = BuildHolos(); LastHoloSegs = n / 6; if (n == 0) return;
            if (_pHolo == 0)
            {
                _pHolo = Link(VS_HOLO, FS_HOLO, "holograms");
                var ids = new uint[1]; glGenVertexArrays(1, ids); _hVao = ids[0]; glBindVertexArray(_hVao);
                glGenBuffers(1, ids); _hVbo = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _hVbo);
                int st = HSTRIDE * 4; int[] sizes = { 3, 3, 3, 2, 3, 3 }; int off = 0;
                for (int a = 0; a < 6; a++) { glEnableVertexAttribArray((uint)a); glVertexAttribPointer((uint)a, sizes[a], GL_FLOAT, 0, st, new IntPtr(off * 4)); off += sizes[a]; }
            }
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            glUseProgram(_pHolo); Func<string, int> L = s => glGetUniformLocation(_pHolo, s);
            glUniformMatrix4fv(L("uView"), 1, 0, _view); glUniform2f(L("uF"), _focal * VHf / W, _focal * VHf / H);
            glUniform1f(L("uNear"), NearZ); glUniform1f(L("uOffY"), OffY); glUniform2f(L("uHalf"), W * 0.5f, H * 0.5f);
            float[] V = _view; float tx = V[12], ty = V[13], tz = V[14];
            glUniform3f(L("uEye"), -(V[0] * tx + V[1] * ty + V[2] * tz), -(V[4] * tx + V[5] * ty + V[6] * tz), -(V[8] * tx + V[9] * ty + V[10] * tz));
            glBindVertexArray(_hVao); glBindBuffer(GL_ARRAY_BUFFER, _hVbo);
            glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)n * HSTRIDE * 4), _hVerts, GL_STREAM_DRAW);
            glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(0); glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST);
            glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE); glColorMask(1, 1, 1, 1);
            float res = H / 1200f;
            glUniform1f(L("uWidth"), HoloHalo * res); glUniform1f(L("uAlpha"), 0.22f); glUniform1i(L("uCore"), 0); glDrawArrays(GL_TRIANGLES, 0, n);
            glUniform1f(L("uWidth"), HoloCore * res); glUniform1f(L("uAlpha"), 0.95f); glUniform1i(L("uCore"), 1); glDrawArrays(GL_TRIANGLES, 0, n);
            glDisable(GL_BLEND); glDepthMask(1); glBindVertexArray(0);
        }

        // ---- THE SWEEP SEES THROUGH WALLS (Josh, 2026-10-13: "Is it possible to see these wireframes through walls? Many of
        // the rooms have the player positioned behind a door on first arrival, and I see only the wireframes of a small portion
        // of the room ... so the player sees the full room mapping wireframe would be ideal") ------------------------------------
        // Every edge of the room's own geometry -- not what moves, not the invisible volumes, and not an edge between two faces
        // of one flat surface (the room's shape, not its triangulation) -- as lines of a constant width on the screen (the
        // holograms' quads, cut at the near plane), drawn ONLY where the room hides them: each line pixel is tested against a
        // copy of the picture's depth and kept when it lies more than MatXrayMargin (a share of the distance) + 2 units behind
        // what is shown; the room's own pass draws the outlines that are in view. Timed and faded as those are (the same fronts
        // from the eye: drawn as the wire front reaches the line's own distance, gone with the texture front's trail), a little
        // dimmer (MatXrayK). The edges are gathered once a sweep (BuildXray, ~1 ms) and kept on the card.
        public bool MatXray = true; public float MatXrayK = 0.6f, MatXrayMargin = 0.03f, MatXrayCore = 0.8f, MatXrayHalo = 3f;
        public int LastXraySegs;
        uint _pXray, _xVao, _xVbo; int _xN, _xBuiltFor = -1, _matSweep;
        const int XSTRIDE = 8;      // a vertex: end A, end B, (end, side)
        const string VS_XRAY = @"#version 400 core
layout(location = 0) in vec3 aA; layout(location = 1) in vec3 aB; layout(location = 2) in vec2 aES;
uniform mat4 uView; uniform vec2 uF; uniform float uNear, uOffY; uniform vec2 uHalf; uniform float uWidth;
out vec3 vW; out float vSide;
vec4 clipOf(vec3 w) { vec4 p = uView * vec4(w, 1.0); return vec4(p.x * uF.x, -p.y * uF.y + uOffY * p.z, uNear, p.z); }
void main() {
    vec3 wa = aA, wb = aB; vec4 a = clipOf(wa), b = clipOf(wb);
    vSide = aES.y; vW = wa;
    float lim = max(uNear, 1.0);
    if (a.w < lim && b.w < lim) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }      // (all of it behind the eye)
    // (one end behind the eye: the line cut where it crosses the near plane)
    if (a.w < lim) { wa = mix(wa, wb, (lim - a.w) / (b.w - a.w)); a = clipOf(wa); }
    if (b.w < lim) { wb = mix(wb, wa, (lim - b.w) / (a.w - b.w)); b = clipOf(wb); }
    vec2 sa = a.xy / a.w * uHalf, sb = b.xy / b.w * uHalf, d = sb - sa; float l = length(d);
    vec2 dn = l > 1e-4 ? d / l : vec2(1.0, 0.0), n = vec2(-dn.y, dn.x);
    bool atB = aES.x > 0.5; vec4 c = atB ? b : a; vW = atB ? wb : wa;
    vec2 s = c.xy / c.w * uHalf + n * (aES.y * uWidth) + dn * ((atB ? 0.5 : -0.5) * uWidth);
    gl_Position = vec4(s / uHalf * c.w, c.z, c.w);
}";
        const string FS_XRAY = @"#version 400 core
in vec3 vW; in float vSide;
uniform sampler2D uDepth; uniform float uNear, uMargin, uK; uniform int uCore;
uniform vec4 uMatz, uMatX; uniform vec3 uEye, uCol, uFlare;
out vec4 oColor;
void main() {
    // only where the room hides it (reversed depth: uNear / depth = the distance along the view)
    float dS = texelFetch(uDepth, ivec2(gl_FragCoord.xy), 0).r;
    float zF = uNear / max(gl_FragCoord.z, 1e-12);
    if (dS > 0.0 && zF < (uNear / dS) * (1.0 + uMargin) + 2.0) discard;
    // the sweep at this point of the line, as the room's own outlines have it (FS_MAIN)
    float d = length(vW - uEye), band = uMatz.y;
    float behindT = uMatz.x - d, behindW = uMatz.z - d;
    float drawn = smoothstep(-0.3 * band, 0.3 * band, behindW);
    if (drawn <= 0.001) discard;
    float wireHot = exp(-abs(behindW) / (0.45 * band));
    float reveal = smoothstep(-0.25 * band, 1.4 * band, behindT);
    float front = exp(-abs(behindT) / (0.6 * band));
    float trail = behindT > 0.0 ? 1.0 - smoothstep(0.35, 1.0, behindT / (uMatX.z * uMatX.y)) : 0.0;
    float lines = drawn * (mix(0.55, 1.0, max(wireHot, front)) * (1.0 - reveal) + max(front, 0.75 * trail) * reveal);
    float e = abs(vSide);
    float a = uCore != 0 ? 1.0 - smoothstep(0.45, 1.0, e) : (1.0 - e) * (1.0 - e);
    oColor = vec4((uCol * lines + uFlare * (0.6 * wireHot * drawn)) * (a * uK), 0.0);
}";
        // ---- THE VISOR'S ECHO SCAN (Josh, 2026-10-14: "tap a key and an amber pulse ripples through the room like the map's
        // intro wave. It outlines doors, pickups and creatures through the walls for a second"). EchoT: seconds since the
        // ping (below 0 = none). The shell runs out from the eye at EchoSpeed to EchoMax, a band of amber light on the room's
        // surfaces (FS_MAIN uEcho); each target's outline lights through the walls as the shell reaches it, flares, and fades
        // over EchoFade. Targets per category (0 doors, 1 items, 2 creatures): triangles of the room as drawn (their feature
        // edges), or line segments (doorway openings).
        public float EchoT = -1f, EchoSpeed = 950f, EchoMax = 1900f, EchoFade = 1.4f, EchoBand = 26f, EchoShell = 1f;
        public int[] EchoColours = { 0xFFB040, 0xFFE8A8, 0xFF6A38 };
        public int LastEchoEdges;
        readonly int[][] _echoTris = new int[3][]; readonly float[][] _echoSegs = new float[3][]; readonly bool[] _echoDirty = { true, true, true };
        readonly uint[] _echoVao = new uint[3], _echoVbo = new uint[3]; readonly int[] _echoN = new int[3];
        uint _pEcho;
        /// <summary>A category's targets: triangles of the room (indices; the edges are built from the room as drawn each time
        /// it is set -- creatures are set again every frame, as they move) and/or extra line segments (6 floats each).</summary>
        public void SetEchoTargets(int cat, int[] tris, float[] segs) { if (cat < 0 || cat > 2) return; _echoTris[cat] = tris; _echoSegs[cat] = segs; _echoDirty[cat] = true; }
        float[] EchoEdges(float[] vx, int[] idx, int[] tris, float[] segs, out int nVerts)
        {
            var o = new List<float>();
            if (tris != null && tris.Length > 0)
            {
                // the feature edges of those triangles: every edge but the ones two of them share lying flat together
                var edges = new Dictionary<long, int>(); var eA = new List<int>(); var eB = new List<int>(); var eN = new List<float[]>(); var eC = new List<int>(); var eFlat = new List<bool>();
                int nv = vx.Length / 3;
                foreach (int t in tris)
                {
                    if (t < 0 || t * 3 + 2 >= idx.Length) continue;
                    int[] v = { idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2] };
                    if (v[0] >= nv || v[1] >= nv || v[2] >= nv) continue;
                    float ux = vx[v[1] * 3] - vx[v[0] * 3], uy = vx[v[1] * 3 + 1] - vx[v[0] * 3 + 1], uz = vx[v[1] * 3 + 2] - vx[v[0] * 3 + 2];
                    float wx = vx[v[2] * 3] - vx[v[0] * 3], wy = vx[v[2] * 3 + 1] - vx[v[0] * 3 + 1], wz = vx[v[2] * 3 + 2] - vx[v[0] * 3 + 2];
                    float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx, nl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz);
                    if (nl < 1e-6f) continue; var n = new[] { nx / nl, ny / nl, nz / nl };
                    for (int k = 0; k < 3; k++)
                    {
                        int a = v[k], b = v[(k + 1) % 3]; if (a > b) { int s = a; a = b; b = s; }
                        long key = ((long)a << 32) | (uint)b; int ei;
                        if (!edges.TryGetValue(key, out ei)) { edges[key] = eA.Count; eA.Add(a); eB.Add(b); eN.Add(n); eC.Add(1); eFlat.Add(false); }
                        else { eC[ei]++; float d = eN[ei][0] * n[0] + eN[ei][1] * n[1] + eN[ei][2] * n[2]; if (eC[ei] == 2 && Math.Abs(d) > 0.9995f) eFlat[ei] = true; else eFlat[ei] = false; }
                    }
                }
                for (int e = 0; e < eA.Count; e++)
                {
                    if (eFlat[e] && eC[e] == 2) continue;
                    int a = eA[e] * 3, b = eB[e] * 3;
                    MapSeg(o, vx[a], vx[a + 1], vx[a + 2], vx[b], vx[b + 1], vx[b + 2]);
                }
            }
            if (segs != null) for (int i = 0; i + 5 < segs.Length; i += 6) MapSeg(o, segs[i], segs[i + 1], segs[i + 2], segs[i + 3], segs[i + 4], segs[i + 5]);
            nVerts = o.Count / XSTRIDE; return o.ToArray();
        }
        void DrawEcho(float[] vx, int[] idx)
        {
            LastEchoEdges = 0;
            if (EchoT < 0f) return;
            if (_pEcho == 0)
            {
                _pEcho = Link(VS_XRAY, FS_ECHO, "the echo's outlines");
                for (int c = 0; c < 3; c++)
                {
                    var ids = new uint[1]; glGenVertexArrays(1, ids); _echoVao[c] = ids[0]; glBindVertexArray(_echoVao[c]);
                    glGenBuffers(1, ids); _echoVbo[c] = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _echoVbo[c]);
                    int st = XSTRIDE * 4; int[] sizes = { 3, 3, 2 }; int off = 0;
                    for (int a = 0; a < 3; a++) { glEnableVertexAttribArray((uint)a); glVertexAttribPointer((uint)a, sizes[a], GL_FLOAT, 0, st, new IntPtr(off * 4)); off += sizes[a]; }
                }
            }
            for (int c = 0; c < 3; c++)
            {
                if (!_echoDirty[c]) continue;
                _echoDirty[c] = false; int n;
                var verts = EchoEdges(vx, idx, _echoTris[c], _echoSegs[c], out n); _echoN[c] = n;
                glBindVertexArray(_echoVao[c]); glBindBuffer(GL_ARRAY_BUFFER, _echoVbo[c]);
                if (n > 0) glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)n * XSTRIDE * 4), verts, GL_STREAM_DRAW);
            }
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            glUseProgram(_pEcho); Func<string, int> L = s => glGetUniformLocation(_pEcho, s);
            glUniformMatrix4fv(L("uView"), 1, 0, _view); glUniform2f(L("uF"), _focal * VHf / W, _focal * VHf / H);
            glUniform1f(L("uNear"), NearZ); glUniform1f(L("uOffY"), OffY); glUniform2f(L("uHalf"), W * 0.5f, H * 0.5f);
            float[] V = _view; float tx = V[12], ty = V[13], tz = V[14];
            glUniform3f(L("uEye"), -(V[0] * tx + V[1] * ty + V[2] * tz), -(V[4] * tx + V[5] * ty + V[6] * tz), -(V[8] * tx + V[9] * ty + V[10] * tz));
            float R = Math.Min(EchoMax, EchoT * EchoSpeed), tail = Math.Max(0f, EchoT - EchoMax / Math.Max(1f, EchoSpeed));
            glUniform4f(L("uEcho"), R, Math.Max(0.1f, EchoFade), Math.Max(1f, EchoSpeed), tail);
            glDisable(GL_DEPTH_TEST); glDepthMask(0); glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST);
            glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE); glColorMask(1, 1, 1, 0);
            float res = H / 1200f;
            for (int c = 0; c < 3; c++)
            {
                if (_echoN[c] == 0) continue; LastEchoEdges += _echoN[c] / 6;
                int col = EchoColours[c];
                glUniform3f(L("uCol"), ((col >> 16) & 255) / 255f, ((col >> 8) & 255) / 255f, (col & 255) / 255f);
                glBindVertexArray(_echoVao[c]);
                glUniform1f(L("uWidth"), 4.5f * res); glUniform1f(L("uK"), 0.30f); glUniform1i(L("uCore"), 0); glDrawArrays(GL_TRIANGLES, 0, _echoN[c]);
                glUniform1f(L("uWidth"), 1.1f * res); glUniform1f(L("uK"), 1.1f); glUniform1i(L("uCore"), 1); glDrawArrays(GL_TRIANGLES, 0, _echoN[c]);
            }
            glDisable(GL_BLEND); glColorMask(1, 1, 1, 1); glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(1); glBindVertexArray(0);
            Check("the echo's outlines");
        }
        const string FS_ECHO = @"#version 400 core
in vec3 vW; in float vSide;
uniform float uK; uniform int uCore; uniform vec3 uEye, uCol;
uniform vec4 uEcho;      // the shell's radius now, how long an outline lasts after it passes (s), the shell's speed, seconds since it reached its end
out vec4 oColor;
void main() {
    float d = length(vW - uEye);
    if (d > uEcho.x) discard;                                           // (the shell has not reached it yet)
    float since = (uEcho.x - d) / uEcho.z + uEcho.w;                    // seconds since the shell passed this point
    float k = exp(-since / uEcho.y) * (1.0 + 2.2 * exp(-since / 0.09));      // a flare as it is struck, then dying away
    float e = abs(vSide);
    float a = uCore != 0 ? 1.0 - smoothstep(0.45, 1.0, e) : (1.0 - e) * (1.0 - e);
    oColor = vec4(mix(uCol, vec3(1.0), 0.35 * exp(-since / 0.09)) * (a * uK * k), 0.0);
}";
        /// <summary>The room's edges for the lines through the walls: 6 vertices (two triangles) an edge.</summary>
        float[] BuildXray(float[] vx, int[] idx, int[] triTex, Raster.Tex[] texes, out int nVerts)
        {
            int nv = vx.Length / 3; var canon = new int[nv]; var at = new Dictionary<long, int>(nv);
            for (int v = 0; v < nv; v++)
            {
                long kx = (long)Math.Round(vx[v * 3] * 20.0) + (1L << 20), ky = (long)Math.Round(vx[v * 3 + 1] * 20.0) + (1L << 20), kz = (long)Math.Round(vx[v * 3 + 2] * 20.0) + (1L << 20);
                long k = ((kx & 0x1FFFFF) << 42) | ((ky & 0x1FFFFF) << 21) | (kz & 0x1FFFFF);
                int c; if (!at.TryGetValue(k, out c)) { c = v; at[k] = v; }
                canon[v] = c;
            }
            // an edge: its ends, the first face's normal, how many faces share it, whether two of them lie flat together
            var edges = new Dictionary<long, int>(); var eA = new List<int>(); var eB = new List<int>(); var eN = new List<float[]>(); var eCount = new List<int>(); var eFlat = new List<bool>();
            int nt = Math.Min(idx.Length / 3, triTex.Length);
            for (int t = 0; t < nt; t++)
            {
                int tt = triTex[t]; if (tt < 0 || tt >= texes.Length || texes[tt] == null || texes[tt].Moves || texes[tt].Ghost) continue;
                int i0 = canon[idx[t * 3]], i1 = canon[idx[t * 3 + 1]], i2 = canon[idx[t * 3 + 2]];
                if (i0 == i1 || i1 == i2 || i0 == i2) continue;
                float ux = vx[i1 * 3] - vx[i0 * 3], uy = vx[i1 * 3 + 1] - vx[i0 * 3 + 1], uz = vx[i1 * 3 + 2] - vx[i0 * 3 + 2];
                float wx = vx[i2 * 3] - vx[i0 * 3], wy = vx[i2 * 3 + 1] - vx[i0 * 3 + 1], wz = vx[i2 * 3 + 2] - vx[i0 * 3 + 2];
                float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx, nl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz);
                if (nl < 1e-6f) continue;
                var nrm = new[] { nx / nl, ny / nl, nz / nl };
                for (int s = 0; s < 3; s++)
                {
                    int a = s == 0 ? i0 : s == 1 ? i1 : i2, b = s == 0 ? i1 : s == 1 ? i2 : i0;
                    long ek = (long)Math.Min(a, b) * nv + Math.Max(a, b); int e;
                    if (!edges.TryGetValue(ek, out e)) { edges[ek] = eA.Count; eA.Add(a); eB.Add(b); eN.Add(nrm); eCount.Add(1); eFlat.Add(false); continue; }
                    int cnt = ++eCount[e]; var n0 = eN[e];
                    eFlat[e] = cnt == 2 && Math.Abs(n0[0] * nrm[0] + n0[1] * nrm[1] + n0[2] * nrm[2]) > 0.9995f;
                }
            }
            int keep = 0; for (int e = 0; e < eA.Count; e++) if (!eFlat[e]) keep++;
            var f = new float[keep * 6 * XSTRIDE]; int o = 0;
            for (int e = 0; e < eA.Count; e++)
            {
                if (eFlat[e]) continue;
                int a = eA[e], b = eB[e];
                for (int v = 0; v < 6; v++)
                {
                    float end = (v == 1 || v == 2 || v == 4) ? 1f : 0f, side = (v == 2 || v == 4 || v == 5) ? 1f : -1f;
                    f[o] = vx[a * 3]; f[o + 1] = vx[a * 3 + 1]; f[o + 2] = vx[a * 3 + 2]; f[o + 3] = vx[b * 3]; f[o + 4] = vx[b * 3 + 1]; f[o + 5] = vx[b * 3 + 2];
                    f[o + 6] = end; f[o + 7] = side; o += XSTRIDE;
                }
            }
            nVerts = keep * 6;
            return f;
        }
        void DrawXray(float[] vx, int[] idx, int[] triTex, Raster.Tex[] texes)
        {
            if (_pXray == 0)
            {
                _pXray = Link(VS_XRAY, FS_XRAY, "the sweep's lines through walls");
                var ids = new uint[1]; glGenVertexArrays(1, ids); _xVao = ids[0]; glBindVertexArray(_xVao);
                glGenBuffers(1, ids); _xVbo = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _xVbo);
                int st = XSTRIDE * 4; int[] sizes = { 3, 3, 2 }; int off = 0;
                for (int a = 0; a < 3; a++) { glEnableVertexAttribArray((uint)a); glVertexAttribPointer((uint)a, sizes[a], GL_FLOAT, 0, st, new IntPtr(off * 4)); off += sizes[a]; }
            }
            if (_xBuiltFor != _matSweep)
            {
                _xBuiltFor = _matSweep;
                var verts = BuildXray(vx, idx, triTex, texes, out _xN);
                glBindVertexArray(_xVao); glBindBuffer(GL_ARRAY_BUFFER, _xVbo);
                if (_xN > 0) glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)_xN * XSTRIDE * 4), verts, GL_STREAM_DRAW);
            }
            LastXraySegs = _xN / 6; if (_xN == 0) return;
            Blit(_fbo, _surfFbo);      // (the picture's depth as it stands, for each line pixel's test)
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            glUseProgram(_pXray); Func<string, int> L = s => glGetUniformLocation(_pXray, s);
            glUniformMatrix4fv(L("uView"), 1, 0, _view); glUniform2f(L("uF"), _focal * VHf / W, _focal * VHf / H);
            glUniform1f(L("uNear"), NearZ); glUniform1f(L("uOffY"), OffY); glUniform2f(L("uHalf"), W * 0.5f, H * 0.5f);
            float[] V = _view; float tx = V[12], ty = V[13], tz = V[14];
            glUniform3f(L("uEye"), -(V[0] * tx + V[1] * ty + V[2] * tz), -(V[4] * tx + V[5] * ty + V[6] * tz), -(V[8] * tx + V[9] * ty + V[10] * tz));
            glUniform4f(L("uMatz"), _mfTex, Math.Max(1f, MatBand), _mfWire, 1f);
            glUniform4f(L("uMatX"), _matT, Math.Max(0.05f, MatTrail), Math.Max(1f, MatSpeed), Math.Max(0f, MatDots));
            glUniform3f(L("uCol"), ((MatColor >> 16) & 255) / 255f, ((MatColor >> 8) & 255) / 255f, (MatColor & 255) / 255f);
            glUniform3f(L("uFlare"), ((MatFlare >> 16) & 255) / 255f, ((MatFlare >> 8) & 255) / 255f, (MatFlare & 255) / 255f);
            glUniform1f(L("uMargin"), Math.Max(0f, MatXrayMargin));
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _surfTex); glUniform1i(L("uDepth"), 0);
            glDisable(GL_DEPTH_TEST); glDepthMask(0); glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST);
            glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE); glColorMask(1, 1, 1, 0);      // (alpha: the placed lights' share, for the fog -- left alone)
            glBindVertexArray(_xVao);
            float res = H / 1200f;
            glUniform1f(L("uWidth"), MatXrayHalo * res); glUniform1f(L("uK"), MatXrayK * 0.22f); glUniform1i(L("uCore"), 0); glDrawArrays(GL_TRIANGLES, 0, _xN);
            glUniform1f(L("uWidth"), MatXrayCore * res); glUniform1f(L("uK"), MatXrayK); glUniform1i(L("uCore"), 1); glDrawArrays(GL_TRIANGLES, 0, _xN);
            glDisable(GL_BLEND); glColorMask(1, 1, 1, 1); glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(1); glBindVertexArray(0);
            Check("the sweep's lines through walls");
        }

        // ---- THE MAP (Josh, 2026-10-14: "revamp the maps ... the same 3d wireframes we've used for roomscanning ... when a player
        // clicks the map button ... a dimmed version of the visor view, the world behind faded back but still visible. We then see
        // the 3d wireframe, with basic shading in place but no textures. The user can click to rotate the map, and the arrows that
        // indicate doors etc are still in place as they are in the original game, but in modern vector graphics"). The room seen
        // from outside, turning about its middle (MapYaw / MapPitch, degrees; MapZoom): its faces CUT AWAY where they face from the
        // eye -- the room is built to be seen from inside, so dropping the faces turned away from an outside eye removes the near
        // walls and the ceiling (a doll's house) -- shaded flat in the scan's teal (no textures), its edges as the materialize
        // sweep's glowing lines (BuildXray: the room's shape, not its triangles; dimmer where hidden), and its marks: amber arrows
        // on the doors' floor pads, pointing out, sliding gently; the player's ring and the way they face. Drawn into its own layer
        // (premultiplied) the compose lays over the picture, which it dims by MapDim as the map fades in (MapK).
        public bool MapOn; public float MapK, MapYaw = 30f, MapPitch = 52f, MapZoom = 1f, MapDim = 0.72f, MapFovDeg = 34f;
        public int MapInk = 0x5FD8C0, MapFlare = 0xCFFFF4, MapMarkInk = 0xFFB040, MapMarkHot = 0xFFE3A6;
        /// <summary>Which way round the room's faces are wound for an eye outside it (the cut-away keeps the faces whose winding
        /// is this way round on screen; flip if the map shows the ceiling instead of the floor).</summary>
        public bool MapCullFlip;
        /// <summary>THE MAP PULSES IN (Josh, 2026-10-14: "When the maps first load, I want them to quickly animate in by the
        /// wireframes 'pulsing' in as the animate from one side to the other, like they grow from nothing to larger, then back to
        /// normal size in a wave across the geometry, then becoming interactive"). Seconds since the map opened (below 0 = no
        /// intro: as it is); each edge and face grows about its own middle from nothing to MapPulse over full size and settles,
        /// as a wave crosses the room from the screen's left to its right in MapIntroSeconds (its front MapWaveWidth of the room
        /// wide), glowing as it passes; the marks come in as it ends.</summary>
        public float MapIntro = -1f, MapIntroSeconds = 1.1f, MapWaveWidth = 0.35f, MapPulse = 0.35f;
        /// <summary>Lines and faces: how bright the edges are where seen / where hidden, how opaque the shaded faces are.</summary>
        public float MapLineK = 1f, MapHiddenK = 0.28f, MapFaceK = 0.38f, MapCore = 1.1f, MapHalo = 4.5f;
        public int LastMapEdges, LastMapFaces; public double LastMapMs;
        float[] _mapMarks = new float[0]; int _mapMarkN;
        /// <summary>The map's marks, 8 floats each: x, y, z (room units), direction x, z (a door: which way is out; the player:
        /// which way they face), kind (0 = a door, 1 = the player), size (units; 0 = the default), 0.</summary>
        public void SetMapMarks(float[] m, int n) { _mapMarks = m ?? new float[0]; _mapMarkN = Math.Max(0, Math.Min(n, _mapMarks.Length / 8)); }
        /// <summary>THE ROOM WITHOUT ITS DOORWAY PICTURES (Josh, 2026-10-14: "we dont want to include door geometry in the maps ... the
        /// alternate door polygons which float outside of the actual map. So all secondary door geometry needs removed"): the
        /// triangles the map leaves out -- every doorway's painted views of the next room (portals.json 'views', the parked
        /// alternates among them), and the characters. Null = none. Setting it builds the map's geometry again.</summary>
        public void SetMapSkip(int[] tris) { _mapSkip = tris; _mapFor = null; }
        /// <summary>THE MAP CUT UNDER THE FLOOR (Josh, 2026-10-14, Room Review MINEHEAD/8: "all other geometry that extends under the main
        /// floor in this room need omitted from the map view" -- the room's walls run on down into the chasm): the triangles flagged
        /// (true) are cut at height y -- what lies under it leaves the map, what crosses it is clipped along it. NaN = no cut. A room's
        /// "map": { "hideBelow", "keep" } (LoadRoom.ps1 Get-AztMapCut). Setting it builds the map's geometry again.</summary>
        public void SetMapCut(float y, bool[] tris) { _mapCutY = y; _mapCut = tris; _mapFor = null; }
        float _mapCutY = float.NaN; bool[] _mapCut;
        /// <summary>The triangles flagged in cut[] clipped to y >= cutY (Sutherland-Hodgman, so the winding is kept): what is wholly under
        /// it is dropped, what crosses it becomes one or two triangles ending on it; the rest are copied as they are. The vertices are
        /// all kept (indices stay valid), the new ones added after them. Per triangle out, the triTex of the triangle it came from.</summary>
        public static void ClipMapBelow(float[] vx, int[] idx, int[] triTex, bool[] cut, float cutY, out float[] vxOut, out int[] idxOut, out int[] ttOut)
        {
            var v = new List<float>(vx); var io = new List<int>(idx.Length); var to = new List<int>(idx.Length / 3);
            var made = new Dictionary<long, int>();
            int nv0 = vx.Length / 3, nt = Math.Min(idx.Length / 3, triTex.Length);
            Func<int, int, int> cross = (a, b) =>
            {
                long k = (long)Math.Min(a, b) * nv0 + Math.Max(a, b); int r;
                if (made.TryGetValue(k, out r)) return r;
                float ya = vx[a * 3 + 1], yb = vx[b * 3 + 1], s = (cutY - ya) / (yb - ya);
                r = v.Count / 3; made[k] = r;
                v.Add(vx[a * 3] + (vx[b * 3] - vx[a * 3]) * s); v.Add(cutY); v.Add(vx[a * 3 + 2] + (vx[b * 3 + 2] - vx[a * 3 + 2]) * s);
                return r;
            };
            var poly = new List<int>(4);
            for (int t = 0; t < nt; t++)
            {
                int i0 = idx[t * 3], i1 = idx[t * 3 + 1], i2 = idx[t * 3 + 2];
                bool c0 = vx[i0 * 3 + 1] >= cutY, c1 = vx[i1 * 3 + 1] >= cutY, c2 = vx[i2 * 3 + 1] >= cutY;
                if (cut == null || t >= cut.Length || !cut[t] || (c0 && c1 && c2)) { io.Add(i0); io.Add(i1); io.Add(i2); to.Add(triTex[t]); continue; }
                if (!c0 && !c1 && !c2) continue;
                poly.Clear(); int[] q = { i0, i1, i2 }; bool[] inn = { c0, c1, c2 };
                for (int s = 0; s < 3; s++)
                {
                    int a = q[s], b = q[(s + 1) % 3]; bool ia = inn[s], ib = inn[(s + 1) % 3];
                    if (ia) poly.Add(a);
                    if (ia != ib) poly.Add(cross(a, b));
                }
                for (int s = 1; s + 1 < poly.Count; s++) { io.Add(poly[0]); io.Add(poly[s]); io.Add(poly[s + 1]); to.Add(triTex[t]); }
            }
            vxOut = v.ToArray(); idxOut = io.ToArray(); ttOut = to.ToArray();
        }
        /// <summary>THE WHOLE COMPLEX (Josh, 2026-10-14: "from a room's 3D map, zoom out to every room you've visited, laid out in
        /// place and linked by their doorways ... unvisited rooms stay as faint outlines"): the OTHER rooms, already placed in this
        /// room's coordinates (through the doorways' transforms), as one soup -- vertices, triangles, and per triangle its group
        /// (1 = visited, 2 = known but not visited: faint). Drawn round the current room as the map zooms out (MapComplexK).
        /// Null = none.</summary>
        public void SetMapComplex(float[] vx, int[] idx, int[] grp) { _mcV = vx; _mcI = idx; _mcG = grp; _mcDirty = true; }
        /// <summary>How much of the rest of the complex shows (0..1; the watcher fades it in as the map zooms out past the
        /// room); MapComplexDim: the unvisited rooms' share of the visited ones' strength.</summary>
        public float MapComplexK, MapComplexDim = 0.14f;
        /// <summary>At the furthest zoom, the lines' width and strength as shares of their weight close up.</summary>
        public float MapFarWidth = 0.45f, MapFarK = 0.45f;
        /// <summary>The map view's faint interlace: how much darker its lines are (0 = none; Josh, 2026-10-14: "very low opacity,
        /// something like 5-10%").</summary>
        public float MapLines = 0.08f;
        /// <summary>The rooms the player is not in: their strength as a share of the current room's (Josh, 2026-10-14: 0.75, then
        /// "slightly more transparent").</summary>
        public float MapOtherK = 0.55f;
        /// <summary>The rooms not yet reached: a faint grey outline rather than the map's teal (Josh, 2026-10-14: "rooms that have
        /// not yet been discovered to be a fainter gray outline, so they remain rather hidden ... Only after the player reaches the
        /// room will it become the current faded teal"); its glow's colour beside it.</summary>
        public int MapUnseenInk = 0x6C7278, MapUnseenFlare = 0x8C9298;
        public int LastComplexFaces;
        float[] _mcV; int[] _mcI, _mcG; bool _mcDirty; float _mcR;
        readonly uint[] _mcFVao = new uint[2], _mcFVbo = new uint[2], _mcLVao = new uint[2], _mcLVbo = new uint[2]; readonly int[] _mcFN = new int[2], _mcLN = new int[2];
        void BuildComplex()
        {
            _mcDirty = false; _mcR = 0f;
            for (int g = 0; g < 2; g++) { _mcFN[g] = 0; _mcLN[g] = 0; }
            if (_mcV == null || _mcI == null || _mcG == null) return;
            var dummy = new[] { new Raster.Tex(new byte[1], 1, 1) };
            for (int g = 0; g < 2; g++)
            {
                if (_mcFVao[g] == 0)
                {
                    var ids = new uint[1];
                    glGenVertexArrays(1, ids); _mcFVao[g] = ids[0]; glBindVertexArray(_mcFVao[g]); glGenBuffers(1, ids); _mcFVbo[g] = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _mcFVbo[g]);
                    glEnableVertexAttribArray(0); glVertexAttribPointer(0, 3, GL_FLOAT, 0, 36, IntPtr.Zero); glEnableVertexAttribArray(1); glVertexAttribPointer(1, 3, GL_FLOAT, 0, 36, new IntPtr(12)); glEnableVertexAttribArray(2); glVertexAttribPointer(2, 3, GL_FLOAT, 0, 36, new IntPtr(24));
                    glGenVertexArrays(1, ids); _mcLVao[g] = ids[0]; glBindVertexArray(_mcLVao[g]); glGenBuffers(1, ids); _mcLVbo[g] = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, _mcLVbo[g]);
                    int st = XSTRIDE * 4; int[] sizes = { 3, 3, 2 }; int off = 0;
                    for (int a = 0; a < 3; a++) { glEnableVertexAttribArray((uint)a); glVertexAttribPointer((uint)a, sizes[a], GL_FLOAT, 0, st, new IntPtr(off * 4)); off += sizes[a]; }
                }
                int nt = Math.Min(_mcI.Length / 3, _mcG.Length);
                var tt = new int[nt]; var fv = new List<float>();
                for (int t = 0; t < nt; t++)
                {
                    bool mine = _mcG[t] == g + 1; tt[t] = mine ? 0 : -1; if (!mine) continue;
                    int a = _mcI[t * 3], b = _mcI[t * 3 + 1], c = _mcI[t * 3 + 2];
                    float ax = _mcV[a * 3], ay = _mcV[a * 3 + 1], az = _mcV[a * 3 + 2], bx = _mcV[b * 3], by = _mcV[b * 3 + 1], bz = _mcV[b * 3 + 2], cx = _mcV[c * 3], cy = _mcV[c * 3 + 1], cz = _mcV[c * 3 + 2];
                    float ux = bx - ax, uy = by - ay, uz = bz - az, wx = cx - ax, wy = cy - ay, wz = cz - az;
                    float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx, nl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz);
                    if (nl < 1e-6f) { tt[t] = -1; continue; }
                    nx /= nl; ny /= nl; nz /= nl;
                    float mx = (ax + bx + cx) / 3f, my = (ay + by + cy) / 3f, mz = (az + bz + cz) / 3f;
                    foreach (var q in new[] { new[] { ax, ay, az }, new[] { bx, by, bz }, new[] { cx, cy, cz } })
                    {
                        fv.Add(q[0]); fv.Add(q[1]); fv.Add(q[2]); fv.Add(nx); fv.Add(ny); fv.Add(nz); fv.Add(mx); fv.Add(my); fv.Add(mz);
                        float dx = q[0] - _mapCx, dy = q[1] - _mapCy, dz = q[2] - _mapCz; _mcR = Math.Max(_mcR, (float)Math.Sqrt(dx * dx + dy * dy + dz * dz));
                    }
                }
                _mcFN[g] = fv.Count / 9;
                glBindVertexArray(_mcFVao[g]); glBindBuffer(GL_ARRAY_BUFFER, _mcFVbo[g]);
                if (_mcFN[g] > 0) glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)fv.Count * 4), fv.ToArray(), GL_STREAM_DRAW);
                int ne; var ev = BuildXray(_mcV, _mcI, tt, dummy, out ne); _mcLN[g] = ne;
                glBindVertexArray(_mcLVao[g]); glBindBuffer(GL_ARRAY_BUFFER, _mcLVbo[g]);
                if (ne > 0) glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)ne * XSTRIDE * 4), ev, GL_STREAM_DRAW);
            }
            glBindVertexArray(0);
        }
        /// <summary>THE ROOM'S BODY ONLY (Josh, 2026-10-14: no floating door pieces; then every room): the parts not part of the
        /// room -- parked doors, a parked machine (ORRERY's rings wait 37,000 units below), backdrop planes, props left outside.
        /// Parts whose boxes touch (within `gap` units) are one piece. THE ROOM is the piece holding the most doors (`doors`:
        /// x, y, z triples; then the most vertices); any other piece whose box's middle lies outside the room's box (grown by a
        /// tenth) is stray, so the free-standing things inside the room stay. `skip` marks parts already left out.</summary>
        public static bool[] MapStrayParts(float[] v, int[] vFirst, int[] vCount, bool[] skip, float gap, float[] doors)
        {
            int n = vFirst.Length; var lo = new float[n * 3]; var hi = new float[n * 3]; var ok = new bool[n];
            for (int p = 0; p < n; p++)
            {
                if ((skip != null && p < skip.Length && skip[p]) || vCount[p] <= 0) continue;
                float x0 = float.MaxValue, y0 = float.MaxValue, z0 = float.MaxValue, x1 = float.MinValue, y1 = float.MinValue, z1 = float.MinValue;
                for (int i = vFirst[p]; i < vFirst[p] + vCount[p] && i * 3 + 2 < v.Length; i++)
                {
                    float x = v[i * 3], y = v[i * 3 + 1], z = v[i * 3 + 2];
                    if (x < x0) x0 = x; if (y < y0) y0 = y; if (z < z0) z0 = z; if (x > x1) x1 = x; if (y > y1) y1 = y; if (z > z1) z1 = z;
                }
                if (x0 > x1) continue;
                lo[p * 3] = x0; lo[p * 3 + 1] = y0; lo[p * 3 + 2] = z0; hi[p * 3] = x1; hi[p * 3 + 1] = y1; hi[p * 3 + 2] = z1; ok[p] = true;
            }
            var root = new int[n]; for (int p = 0; p < n; p++) root[p] = p;
            Func<int, int> find = a => { while (root[a] != a) { root[a] = root[root[a]]; a = root[a]; } return a; };
            for (int a = 0; a < n; a++)
            {
                if (!ok[a]) continue;
                for (int b = a + 1; b < n; b++)
                {
                    if (!ok[b]) continue;
                    if (lo[a * 3] - gap > hi[b * 3] || lo[b * 3] - gap > hi[a * 3] || lo[a * 3 + 1] - gap > hi[b * 3 + 1] || lo[b * 3 + 1] - gap > hi[a * 3 + 1] || lo[a * 3 + 2] - gap > hi[b * 3 + 2] || lo[b * 3 + 2] - gap > hi[a * 3 + 2]) continue;
                    int ra = find(a), rb = find(b); if (ra != rb) root[ra] = rb;
                }
            }
            // each piece: its box, its vertices, the doors in it
            var pLo = new Dictionary<int, float[]>(); var pHi = new Dictionary<int, float[]>(); var verts = new Dictionary<int, long>();
            for (int p = 0; p < n; p++)
            {
                if (!ok[p]) continue; int r = find(p); float[] l, h;
                if (!pLo.TryGetValue(r, out l)) { l = new[] { float.MaxValue, float.MaxValue, float.MaxValue }; h = new[] { float.MinValue, float.MinValue, float.MinValue }; pLo[r] = l; pHi[r] = h; verts[r] = 0; }
                else h = pHi[r];
                for (int k = 0; k < 3; k++) { l[k] = Math.Min(l[k], lo[p * 3 + k]); h[k] = Math.Max(h[k], hi[p * 3 + k]); }
                verts[r] += vCount[p];
            }
            int room = -1; int bestDoors = -1; long bestV = -1;
            foreach (var r in pLo.Keys)
            {
                int nd = 0;
                if (doors != null) for (int d = 0; d + 2 < doors.Length; d += 3)
                {
                    bool inside = true; for (int k = 0; k < 3; k++) if (doors[d + k] < pLo[r][k] - 40 || doors[d + k] > pHi[r][k] + 40) inside = false;
                    if (inside) nd++;
                }
                if (nd > bestDoors || (nd == bestDoors && verts[r] > bestV)) { bestDoors = nd; bestV = verts[r]; room = r; }
            }
            var stray = new bool[n]; if (room < 0) return stray;
            float[] rl = pLo[room], rh = pHi[room]; var grow = new float[3]; for (int k = 0; k < 3; k++) grow[k] = (rh[k] - rl[k]) * 0.1f;
            var strayPiece = new Dictionary<int, bool>();
            foreach (var r in pLo.Keys)
            {
                if (r == room) { strayPiece[r] = false; continue; }
                bool inside = true; for (int k = 0; k < 3; k++) { float m = (pLo[r][k] + pHi[r][k]) * 0.5f; if (m < rl[k] - grow[k] || m > rh[k] + grow[k]) inside = false; }
                strayPiece[r] = !inside;
            }
            for (int p = 0; p < n; p++) if (ok[p] && strayPiece[find(p)]) stray[p] = true;
            return stray;
        }        int[] _mapSkip;
        uint _mapFbo, _mapLayerTex, _mapDepth, _pMapFace, _pMapLine, _mfVao, _mfVbo, _mlVao, _mlVbo, _mkVao, _mkVbo, _mkfVao, _mkfVbo;
        int _mfN, _mlN; object _mapFor; float _mapCx, _mapCy, _mapCz, _mapR;
        readonly float[] _mapMvp = new float[16]; float _mapEyeX, _mapEyeY, _mapEyeZ;
        // the intro's wave (both programs): uWave = progress 0..1, the front's width, on, how far past full size; uWaveAx = the
        // screen's left-to-right in the room; uWaveC = the room's middle and radius
        const string MAP_WAVE = @"
uniform vec4 uWave; uniform vec3 uWaveAx; uniform vec4 uWaveC;
// scale and glow of a piece whose middle is at m
vec2 wave(vec3 m) {
    if (uWave.z < 0.5) return vec2(1.0, 0.0);
    float u = clamp((dot(m - uWaveC.xyz, uWaveAx) / max(uWaveC.w, 1.0) + 1.0) * 0.5, 0.0, 1.0);
    float ph = clamp((uWave.x * (1.0 + uWave.y) - u) / uWave.y, 0.0, 1.0);
    float grow = smoothstep(0.0, 0.55, ph) * (1.0 + uWave.w);
    float s = mix(grow, 1.0, smoothstep(0.55, 1.0, ph));
    float glow = smoothstep(0.0, 0.25, ph) * (1.0 - smoothstep(0.45, 1.0, ph));
    return vec2(s, glow);
}
";
        const string VS_MAPF = @"#version 400 core
layout(location = 0) in vec3 aP; layout(location = 1) in vec3 aN; layout(location = 2) in vec3 aC;
uniform mat4 uMvp; out vec3 vP; out vec3 vN; out float vGlow;
" + MAP_WAVE + @"
void main() {
    vec2 w = wave(aC); vec3 p = aC + (aP - aC) * w.x;
    if (w.x < 0.002) { vP = aP; vN = aN; vGlow = 0.0; gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }      // (not reached yet: nothing at all)
    vP = aP; vN = aN; vGlow = w.y; gl_Position = uMvp * vec4(p, 1.0);
}";
        const string FS_MAPF = @"#version 400 core
in vec3 vP; in vec3 vN; in float vGlow;
uniform vec3 uEye, uCol, uLight; uniform float uK; uniform int uFlat, uFlip;
out vec4 oColor;
void main() {
    if (uFlat != 0) { oColor = vec4(uCol * uK, uK); return; }
    vec3 n = normalize(vN), v = normalize(uEye - vP);
    // THE CUT-AWAY: keep the faces turned toward the eye (a room's inside faces its middle, so from outside the near walls and
    // the ceiling are turned away and drop out); which winding counts as 'toward' is uFlip
    bool toward = dot(n, v) > 0.0; if (uFlip != 0) toward = !toward;
    if (!toward) discard;
    if (uFlip != 0) n = -n;
    float lam = max(dot(n, normalize(uLight)), 0.0), up = clamp(n.y, 0.0, 1.0);
    float shade = 0.06 + 0.42 * lam + 0.30 * up;                    // (floors read lightest, walls by the light)
    float rim = pow(1.0 - abs(dot(n, v)), 3.0);                     // (a little edge light on faces seen side-on)
    vec3 c = uCol * (shade + 0.35 * rim) * (1.0 + 1.6 * vGlow);
    oColor = vec4(c * uK, uK);
}";
        const string VS_MAPL = @"#version 400 core
layout(location = 0) in vec3 aA; layout(location = 1) in vec3 aB; layout(location = 2) in vec2 aES;
uniform mat4 uMvp; uniform vec2 uHalf; uniform float uWidth, uBias;
out float vSide; out float vGlow;
" + MAP_WAVE + @"
void main() {
    vec3 mid = (aA + aB) * 0.5; vec2 w = wave(mid);
    if (w.x < 0.002) { vSide = 0.0; vGlow = 0.0; gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }      // (not reached yet: no speck of its line's caps)
    vec4 a = uMvp * vec4(mid + (aA - mid) * w.x, 1.0), b = uMvp * vec4(mid + (aB - mid) * w.x, 1.0);
    vSide = aES.y; vGlow = w.y;
    float lim = 1e-3;
    if (a.w < lim && b.w < lim) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; }
    if (a.w < lim) a = mix(a, b, (lim - a.w) / (b.w - a.w));
    if (b.w < lim) b = mix(b, a, (lim - b.w) / (a.w - b.w));
    vec2 sa = a.xy / a.w * uHalf, sb = b.xy / b.w * uHalf, d = sb - sa; float l = length(d);
    vec2 dn = l > 1e-4 ? d / l : vec2(1.0, 0.0), n = vec2(-dn.y, dn.x);
    bool atB = aES.x > 0.5; vec4 c = atB ? b : a;
    vec2 s = c.xy / c.w * uHalf + n * (aES.y * uWidth) + dn * ((atB ? 0.5 : -0.5) * uWidth);
    gl_Position = vec4(s / uHalf * c.w, c.z - uBias * c.w, c.w);      // (pulled a little toward the eye: no fighting with its faces)
}";
        const string FS_MAPL = @"#version 400 core
in float vSide; in float vGlow;
uniform vec3 uCol; uniform float uK; uniform int uCore;
out vec4 oColor;
void main() {
    float e = abs(vSide);
    float a = uCore != 0 ? 1.0 - smoothstep(0.45, 1.0, e) : (1.0 - e) * (1.0 - e);
    float k = a * uK * (1.0 + 2.0 * vGlow); oColor = vec4(uCol * k, min(1.0, k));
}";
        static float[] MapLookAt(float ex, float ey, float ez, float cx, float cy, float cz)
        {
            float fx = cx - ex, fy = cy - ey, fz = cz - ez, fl = (float)Math.Sqrt(fx * fx + fy * fy + fz * fz); fx /= fl; fy /= fl; fz /= fl;
            float sx = fy * 0 - fz * 1, sy = fz * 0 - fx * 0, sz = fx * 1 - fy * 0, sl = (float)Math.Sqrt(sx * sx + sy * sy + sz * sz);     // s = f x up(0,1,0)
            if (sl < 1e-5f) { sx = 1; sy = 0; sz = 0; sl = 1; }
            sx /= sl; sy /= sl; sz /= sl;
            float ux = sy * fz - sz * fy, uy = sz * fx - sx * fz, uz = sx * fy - sy * fx;
            return new[] { sx, ux, -fx, 0, sy, uy, -fy, 0, sz, uz, -fz, 0, -(sx * ex + sy * ey + sz * ez), -(ux * ex + uy * ey + uz * ez), fx * ex + fy * ey + fz * ez, 1 };
        }
        static float[] MapMul(float[] a, float[] b)      // column-major a x b
        {
            var r = new float[16];
            for (int c = 0; c < 4; c++) for (int rr = 0; rr < 4; rr++) { float s = 0; for (int k = 0; k < 4; k++) s += a[k * 4 + rr] * b[c * 4 + k]; r[c * 4 + rr] = s; }
            return r;
        }
        /// <summary>The room's static geometry for the map, once a room: faces (position + face normal) and its edges.</summary>
        void BuildMap(float[] vx, int[] idx, int[] triTex, Raster.Tex[] texes)
        {
            // (the triangles left out: their texture taken away in a copy, so the faces and the edges both pass them by)
            if (_mapSkip != null && _mapSkip.Length > 0)
            {
                var tt2 = (int[])triTex.Clone();
                foreach (int t in _mapSkip) if (t >= 0 && t < tt2.Length) tt2[t] = -1;
                triTex = tt2;
            }
            // (the cut under the floor: the flagged triangles clipped -- the faces and the edges both see the clipped room)
            if (!float.IsNaN(_mapCutY) && _mapCut != null)
            {
                float[] cv; int[] ci, ct; ClipMapBelow(vx, idx, triTex, _mapCut, _mapCutY, out cv, out ci, out ct);
                vx = cv; idx = ci; triTex = ct;
            }
            int nt = Math.Min(idx.Length / 3, triTex.Length);
            var fv = new List<float>(nt * 18);
            float x0 = float.MaxValue, y0 = float.MaxValue, z0 = float.MaxValue, x1 = float.MinValue, y1 = float.MinValue, z1 = float.MinValue;
            for (int t = 0; t < nt; t++)
            {
                int tt = triTex[t]; if (tt < 0 || tt >= texes.Length || texes[tt] == null || texes[tt].Moves || texes[tt].Ghost) continue;
                int a = idx[t * 3], b = idx[t * 3 + 1], c = idx[t * 3 + 2];
                float ax = vx[a * 3], ay = vx[a * 3 + 1], az = vx[a * 3 + 2], bx = vx[b * 3], by = vx[b * 3 + 1], bz = vx[b * 3 + 2], cx = vx[c * 3], cy = vx[c * 3 + 1], cz = vx[c * 3 + 2];
                float ux = bx - ax, uy = by - ay, uz = bz - az, wx = cx - ax, wy = cy - ay, wz = cz - az;
                float nx = uy * wz - uz * wy, ny = uz * wx - ux * wz, nz = ux * wy - uy * wx, nl = (float)Math.Sqrt(nx * nx + ny * ny + nz * nz);
                if (nl < 1e-6f) continue; nx /= nl; ny /= nl; nz /= nl;
                float mx = (ax + bx + cx) / 3f, my = (ay + by + cy) / 3f, mz = (az + bz + cz) / 3f;
                foreach (var p in new[] { new[] { ax, ay, az }, new[] { bx, by, bz }, new[] { cx, cy, cz } })
                {
                    fv.Add(p[0]); fv.Add(p[1]); fv.Add(p[2]); fv.Add(nx); fv.Add(ny); fv.Add(nz); fv.Add(mx); fv.Add(my); fv.Add(mz);
                    if (p[0] < x0) x0 = p[0]; if (p[1] < y0) y0 = p[1]; if (p[2] < z0) z0 = p[2];
                    if (p[0] > x1) x1 = p[0]; if (p[1] > y1) y1 = p[1]; if (p[2] > z1) z1 = p[2];
                }
            }
            _mfN = fv.Count / 9;
            if (_mfN == 0) { _mapCx = _mapCy = _mapCz = 0; _mapR = 100; } else { _mapCx = (x0 + x1) / 2; _mapCy = (y0 + y1) / 2; _mapCz = (z0 + z1) / 2; _mapR = 0.5f * (float)Math.Sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0)); }
            glBindVertexArray(_mfVao); glBindBuffer(GL_ARRAY_BUFFER, _mfVbo);
            if (_mfN > 0) glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)fv.Count * 4), fv.ToArray(), GL_STREAM_DRAW);
            int ne; var ev = BuildXray(vx, idx, triTex, texes, out ne); _mlN = ne;
            glBindVertexArray(_mlVao); glBindBuffer(GL_ARRAY_BUFFER, _mlVbo);
            if (_mlN > 0) glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)_mlN * XSTRIDE * 4), ev, GL_STREAM_DRAW);
            glBindVertexArray(0);
        }
        // a line from a to b in the lines' vertex layout (6 vertices)
        static void MapSeg(List<float> o, float ax, float ay, float az, float bx, float by, float bz)
        {
            for (int v = 0; v < 6; v++)
            {
                float end = (v == 1 || v == 2 || v == 4) ? 1f : 0f, side = (v == 2 || v == 4 || v == 5) ? 1f : -1f;
                o.Add(ax); o.Add(ay); o.Add(az); o.Add(bx); o.Add(by); o.Add(bz); o.Add(end); o.Add(side);
            }
        }
        /// <summary>The marks for this frame: outlines (lines) and fills (flat triangles, position + a dummy normal).</summary>
        void BuildMarks(float time, List<float> lines, List<float> fills)
        {
            for (int i = 0; i < _mapMarkN; i++)
            {
                int b = i * 8; float x = _mapMarks[b], y = _mapMarks[b + 1] + 1.5f, z = _mapMarks[b + 2], dx = _mapMarks[b + 3], dz = _mapMarks[b + 4];
                float dl = (float)Math.Sqrt(dx * dx + dz * dz); if (dl < 1e-5f) { dx = 0; dz = 1; } else { dx /= dl; dz /= dl; }
                float px = -dz, pz = dx;                                   // (across)
                float sz = _mapMarks[b + 6] > 0 ? _mapMarks[b + 6] : _mapR * 0.06f;
                if (_mapMarks[b + 5] == 0)
                {
                    // A DOOR: a chevron arrow on its pad, pointing out, sliding outward and back (two strokes, the second following)
                    for (int k = 0; k < 2; k++)
                    {
                        float ph = (float)((time * 0.6 + k * 0.5) % 1.0), off = (ph - 0.5f) * sz * 0.5f, fade = (float)Math.Sin(Math.PI * ph);
                        float cx = x + dx * (off + k * sz * 0.35f), cz = z + dz * (off + k * sz * 0.35f);
                        float tx = cx + dx * sz * 0.5f, tz = cz + dz * sz * 0.5f, lx = cx - dx * sz * 0.1f + px * sz * 0.55f, lz = cz - dz * sz * 0.1f + pz * sz * 0.55f;
                        float rx = cx - dx * sz * 0.1f - px * sz * 0.55f, rz = cz - dz * sz * 0.1f - pz * sz * 0.55f;
                        float ix = cx + dx * sz * 0.12f, iz = cz + dz * sz * 0.12f;
                        if (fade > 0.05f)
                        {
                            MapSeg(lines, lx, y, lz, tx, y, tz); MapSeg(lines, tx, y, tz, rx, y, rz); MapSeg(lines, rx, y, rz, ix, y, iz); MapSeg(lines, ix, y, iz, lx, y, lz);
                            foreach (var p in new[] { lx, y, lz, tx, y, tz, ix, y, iz, ix, y, iz, tx, y, tz, rx, y, rz }) fills.Add(p);
                        }
                    }
                    // the pad itself: a faint square under it
                    float h = sz * 0.75f;
                    MapSeg(lines, x - dx * h - px * h, y, z - dz * h - pz * h, x - dx * h + px * h, y, z - dz * h + pz * h);
                    MapSeg(lines, x + dx * h - px * h, y, z + dz * h - pz * h, x + dx * h + px * h, y, z + dz * h + pz * h);
                }
                else
                {
                    // THE PLAYER: a ring, a pulse going out from it, and a wedge the way they face
                    int n = 24; float r = sz * 0.45f, pr = r * (1f + 1.6f * (float)((time * 0.7) % 1.0));
                    for (int k = 0; k < n; k++)
                    {
                        double a0 = 2 * Math.PI * k / n, a1 = 2 * Math.PI * (k + 1) / n;
                        MapSeg(lines, x + r * (float)Math.Cos(a0), y, z + r * (float)Math.Sin(a0), x + r * (float)Math.Cos(a1), y, z + r * (float)Math.Sin(a1));
                    }
                    for (int k = 0; k < n; k += 2)
                    {
                        double a0 = 2 * Math.PI * k / n, a1 = 2 * Math.PI * (k + 1) / n;
                        MapSeg(lines, x + pr * (float)Math.Cos(a0), y, z + pr * (float)Math.Sin(a0), x + pr * (float)Math.Cos(a1), y, z + pr * (float)Math.Sin(a1));
                    }
                    float wx0 = x + dx * r * 1.1f, wz0 = z + dz * r * 1.1f, wtx = x + dx * r * 2.4f, wtz = z + dz * r * 2.4f;
                    float wl = x + dx * r * 1.0f + px * r * 0.6f, wlz = z + dz * r * 1.0f + pz * r * 0.6f, wr = x + dx * r * 1.0f - px * r * 0.6f, wrz = z + dz * r * 1.0f - pz * r * 0.6f;
                    MapSeg(lines, wl, y, wlz, wtx, y, wtz); MapSeg(lines, wtx, y, wtz, wr, y, wrz);
                    foreach (var p in new[] { wl, y, wlz, wtx, y, wtz, wr, y, wrz, x - r * 0.35f, y, z, x + r * 0.35f * 0, y, z + r * 0.35f, x + r * 0.35f, y, z }) fills.Add(p);
                    foreach (var p in new[] { x, y, z + 0, x, y, z, x, y, z }) fills.Add(p);
                }
            }
        }
        /// <summary>Draws the map layer (when MapK > 0): called at the end of Draw, with the room it drew.</summary>
        void DrawMap(float[] vx, int[] idx, int[] triTex, Raster.Tex[] texes)
        {
            var sw = Stopwatch.StartNew();
            if (_mapFbo == 0)
            {
                _pMapFace = Link(VS_MAPF, FS_MAPF, "the map's faces"); _pMapLine = Link(VS_MAPL, FS_MAPL, "the map's lines");
                var ids = new uint[1];
                glGenFramebuffers(1, ids); _mapFbo = ids[0]; glBindFramebuffer(GL_FRAMEBUFFER, _mapFbo);
                _mapLayerTex = ColourTex(); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _mapLayerTex, 0);
                glGenTextures(1, ids); _mapDepth = ids[0]; glBindTexture(GL_TEXTURE_2D, _mapDepth);
                glTexImage2DN(GL_TEXTURE_2D, 0, (int)GL_DEPTH_COMPONENT32F, W, H, 0, GL_DEPTH_COMPONENT, GL_FLOAT, IntPtr.Zero);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, (int)GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, (int)GL_NEAREST);
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, _mapDepth, 0);
                Complete("the map");
                foreach (var pr in new[] { 0, 1, 2, 3 })
                {
                    glGenVertexArrays(1, ids); uint vao = ids[0]; glBindVertexArray(vao); glGenBuffers(1, ids); uint vbo = ids[0]; glBindBuffer(GL_ARRAY_BUFFER, vbo);
                    if (pr == 0 || pr == 3)
                    {
                        int st = (pr == 0 ? 9 : 6) * 4; glEnableVertexAttribArray(0); glVertexAttribPointer(0, 3, GL_FLOAT, 0, st, IntPtr.Zero);
                        if (pr == 0) { glEnableVertexAttribArray(1); glVertexAttribPointer(1, 3, GL_FLOAT, 0, st, new IntPtr(12)); glEnableVertexAttribArray(2); glVertexAttribPointer(2, 3, GL_FLOAT, 0, st, new IntPtr(24)); }
                    }
                    else
                    {
                        int st = XSTRIDE * 4; int[] sizes = { 3, 3, 2 }; int off = 0;
                        for (int a = 0; a < 3; a++) { glEnableVertexAttribArray((uint)a); glVertexAttribPointer((uint)a, sizes[a], GL_FLOAT, 0, st, new IntPtr(off * 4)); off += sizes[a]; }
                    }
                    if (pr == 0) { _mfVao = vao; _mfVbo = vbo; } else if (pr == 1) { _mlVao = vao; _mlVbo = vbo; } else if (pr == 2) { _mkVao = vao; _mkVbo = vbo; } else { _mkfVao = vao; _mkfVbo = vbo; }
                }
                glBindVertexArray(0);
            }
            if (!ReferenceEquals(_mapFor, vx)) { _mapFor = vx; BuildMap(vx, idx, triTex, texes); _mcDirty = true; }
            if (_mcDirty) BuildComplex();
            float cxK = (_mcFN[0] + _mcFN[1] + _mcLN[0] + _mcLN[1]) > 0 ? Math.Max(0f, Math.Min(1f, MapComplexK)) : 0f;
            // the eye: round the room's middle
            float yaw = MapYaw * (float)Math.PI / 180f, pitch = Math.Max(5f, Math.Min(89f, MapPitch)) * (float)Math.PI / 180f;
            float fov = Math.Max(10f, MapFovDeg) * (float)Math.PI / 180f, aspect = (float)W / Math.Max(1f, VHf);
            float dist = _mapR / (float)Math.Sin(fov * 0.5f) * 1.02f / Math.Max(0.03f, MapZoom);      // (zoomed out past the room: the complex round it)
            if (aspect < 1f) dist /= aspect;
            _mapEyeX = _mapCx + dist * (float)(Math.Cos(pitch) * Math.Sin(yaw)); _mapEyeY = _mapCy + dist * (float)Math.Sin(pitch); _mapEyeZ = _mapCz + dist * (float)(Math.Cos(pitch) * Math.Cos(yaw));
            var view = MapLookAt(_mapEyeX, _mapEyeY, _mapEyeZ, _mapCx, _mapCy, _mapCz);
            float reachR = cxK > 0f ? Math.Max(_mapR, _mcR) : _mapR;
            float near = Math.Max(1f, dist - reachR * 1.6f), far = dist + reachR * 1.6f, ff = 1f / (float)Math.Tan(fov * 0.5f);
            // (the picture's VIEW rows: the band the 3D is shown in; the map is framed there, below it nothing is seen)
            float sy = VHf / H;
            var proj = new float[] { ff / aspect, 0, 0, 0, 0, ff, 0, 0, 0, 0, (far + near) / (near - far), -1, 0, 0, 2 * far * near / (near - far), 0 };
            var mvp = MapMul(proj, view);
            // (the picture's row 0 is its TOP, and the view band is its first VHf rows: y is turned over and squeezed into the
            // band -- clip y' = -(sy y) - (1 - sy) w)
            for (int c = 0; c < 4; c++) mvp[c * 4 + 1] = -sy * mvp[c * 4 + 1] - (1f - sy) * mvp[c * 4 + 3];
            // (and x turned over too: the game's world is the other handedness from this look-at, so every map came out MIRRORED
            // -- Josh, 2026-10-14, WASHCORI: its balcony on the left, in the room on the right. Checked against the room's own view)
            for (int c = 0; c < 4; c++) mvp[c * 4] = -mvp[c * 4];
            Array.Copy(mvp, _mapMvp, 16);
            glBindFramebuffer(GL_FRAMEBUFFER, _mapFbo); glViewport(0, 0, W, H);
            glColorMask(1, 1, 1, 1); glDepthMask(1); glClearColor(0, 0, 0, 0); glClearDepth(1.0); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            glDisable(GL_STENCIL_TEST); glDisable(GL_CULL_FACE);
            float k = Math.Max(0f, Math.Min(1f, MapK));
            Func<int, float> R = c => ((c >> 16) & 255) / 255f; Func<int, float> G = c => ((c >> 8) & 255) / 255f; Func<int, float> B = c => (c & 255) / 255f;
            // the intro's wave
            float wp = MapIntro < 0 ? 1f : MapIntro / Math.Max(0.1f, MapIntroSeconds); bool waveOn = MapIntro >= 0 && wp < 1f;
            float wax = -(float)Math.Cos(yaw), waz = (float)Math.Sin(yaw);                         // (the screen's left to right -- x is turned over, see the mirror above)
            Action<uint> setWave = pg =>
            {
                glUseProgram(pg);
                glUniform4f(glGetUniformLocation(pg, "uWave"), Math.Max(0f, wp), Math.Max(0.05f, MapWaveWidth), waveOn ? 1f : 0f, MapPulse);
                glUniform3f(glGetUniformLocation(pg, "uWaveAx"), wax, 0f, waz); glUniform4f(glGetUniformLocation(pg, "uWaveC"), _mapCx, _mapCy, _mapCz, _mapR);
            };
            setWave(_pMapLine); setWave(_pMapFace);
            float markK = waveOn ? Math.Max(0f, Math.Min(1f, (wp - 0.7f) / 0.3f)) : 1f;
            // 1. the faces: depth for the lines' test, the shading over it
            glUseProgram(_pMapFace);
            glUniformMatrix4fv(glGetUniformLocation(_pMapFace, "uMvp"), 1, 0, mvp);
            glUniform3f(glGetUniformLocation(_pMapFace, "uEye"), _mapEyeX, _mapEyeY, _mapEyeZ);
            glUniform3f(glGetUniformLocation(_pMapFace, "uCol"), R(MapInk), G(MapInk), B(MapInk));
            glUniform3f(glGetUniformLocation(_pMapFace, "uLight"), (float)Math.Sin(yaw + 0.8), 1.4f, (float)Math.Cos(yaw + 0.8));
            glUniform1f(glGetUniformLocation(_pMapFace, "uK"), MapFaceK); glUniform1i(glGetUniformLocation(_pMapFace, "uFlat"), 0); glUniform1i(glGetUniformLocation(_pMapFace, "uFlip"), MapCullFlip ? 1 : 0);
            glEnable(GL_DEPTH_TEST); glDepthFunc(0x0201 /*LESS*/);
            glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
            glBindVertexArray(_mfVao); if (_mfN > 0) glDrawArrays(GL_TRIANGLES, 0, _mfN);
            // 2. the edges: where seen, then fainter where the kept faces hide them
            glUseProgram(_pMapLine);
            glUniformMatrix4fv(glGetUniformLocation(_pMapLine, "uMvp"), 1, 0, mvp); glUniform2f(glGetUniformLocation(_pMapLine, "uHalf"), W * 0.5f, H * 0.5f);
            glUniform1f(glGetUniformLocation(_pMapLine, "uBias"), 0.0008f);
            glDepthMask(0); glBlendFunc(GL_ONE, GL_ONE);
            float res = H / 1200f; int uW = glGetUniformLocation(_pMapLine, "uWidth"), uK = glGetUniformLocation(_pMapLine, "uK"), uC = glGetUniformLocation(_pMapLine, "uCore"), uCol = glGetUniformLocation(_pMapLine, "uCol");
            // ZOOMED OUT, FINER LINES (Josh, 2026-10-14: the rooms "very bright when zooming out ... the linework is a thicker
            // weight"): the lines keep their pixel width while the rooms shrink, so they pile up -- thinner and quieter the
            // further out, down to MapFarWidth / MapFarK of their weight at the furthest zoom
            float zk = Math.Max(0f, Math.Min(1f, (MapZoom - 0.06f) / 0.54f)); zk = zk * zk * (3f - 2f * zk);
            res *= MapFarWidth + (1f - MapFarWidth) * zk; float lineK = MapFarK + (1f - MapFarK) * zk;
            glBindVertexArray(_mlVao);
            if (_mlN > 0)
            {
                foreach (var pass in new[] { 0, 1 })
                {
                    glDepthFunc(pass == 0 ? 0x0203u /*LEQUAL*/ : 0x0204u /*GREATER*/);
                    float kk = (pass == 0 ? MapLineK : MapHiddenK) * lineK;
                    glUniform3f(uCol, R(MapInk), G(MapInk), B(MapInk));
                    glUniform1f(uW, MapHalo * res); glUniform1f(uK, kk * 0.22f); glUniform1i(uC, 0); glDrawArrays(GL_TRIANGLES, 0, _mlN);
                    glUniform3f(uCol, R(MapFlare), G(MapFlare), B(MapFlare));
                    glUniform1f(uW, MapCore * res); glUniform1f(uK, kk * 0.8f); glUniform1i(uC, 1); glDrawArrays(GL_TRIANGLES, 0, _mlN);
                }
            }
            // 2b. THE REST OF THE COMPLEX (as the map zooms out): the visited rooms as the room is drawn, the unvisited ones faint;
            // no intro wave on them
            LastComplexFaces = 0;
            if (cxK > 0.01f)
            {
                glUseProgram(_pMapFace); glUniform4f(glGetUniformLocation(_pMapFace, "uWave"), 1f, 0.1f, 0f, 0f);
                glUseProgram(_pMapLine); glUniform4f(glGetUniformLocation(_pMapLine, "uWave"), 1f, 0.1f, 0f, 0f);
                for (int g = 0; g < 2; g++)
                {
                    float gk = cxK * (g == 0 ? MapOtherK : MapComplexDim);      // (visited rooms under the current one: faded teal -- MapOtherK)
                    if (_mcFN[g] > 0)
                    {
                        // (no depth written by the other rooms' faces, and their lines drawn whole: seen from above, rooms below another's
                        // floor were thinned by the hidden-line pass and looked cut off -- Josh, 2026-10-14)
                        glUseProgram(_pMapFace); glDepthMask(0); glDepthFunc(0x0201 /*LESS*/); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                        glUniform1f(glGetUniformLocation(_pMapFace, "uK"), MapFaceK * gk * (g == 0 ? 0.8f : 0.2f));
                        int fInk = g == 0 ? MapInk : MapUnseenInk; glUniform3f(glGetUniformLocation(_pMapFace, "uCol"), R(fInk), G(fInk), B(fInk));
                        glBindVertexArray(_mcFVao[g]); glDrawArrays(GL_TRIANGLES, 0, _mcFN[g]); LastComplexFaces += _mcFN[g] / 3;
                    }
                    if (_mcLN[g] > 0)
                    {
                        glUseProgram(_pMapLine); glDepthMask(0); glBlendFunc(GL_ONE, GL_ONE); glBindVertexArray(_mcLVao[g]);
                        foreach (var pass in new[] { 0 })
                        {
                            glDepthFunc(0x0207u /*ALWAYS*/);
                            float kk = MapLineK * 0.8f * gk * lineK;
                            int lInk = g == 0 ? MapInk : MapUnseenInk, lFlare = g == 0 ? MapInk : MapUnseenFlare;      // (visited: the map's teal, no white-hot core -- that stays the current room's; the unvisited: grey)
                            glUniform3f(uCol, R(lInk), G(lInk), B(lInk));
                            glUniform1f(uW, MapHalo * res); glUniform1f(uK, kk * 0.22f); glUniform1i(uC, 0); glDrawArrays(GL_TRIANGLES, 0, _mcLN[g]);
                            glUniform3f(uCol, R(lFlare), G(lFlare), B(lFlare));
                            glUniform1f(uW, MapCore * res); glUniform1f(uK, kk * 0.8f); glUniform1i(uC, 1); glDrawArrays(GL_TRIANGLES, 0, _mcLN[g]);
                        }
                    }
                }
                glUseProgram(_pMapLine);
            }
            LastMapEdges = _mlN / 6; LastMapFaces = _mfN / 3;
            // 3. the marks: over everything, amber
            if (_mapMarkN > 0 && markK > 0.01f)
            {
                var ml = new List<float>(); var mf = new List<float>(); BuildMarks(Time, ml, mf);
                glDisable(GL_DEPTH_TEST);
                if (mf.Count > 0)
                {
                    var fa = new float[mf.Count / 3 * 6]; for (int i = 0, j = 0; i < mf.Count; i += 3, j += 6) { fa[j] = mf[i]; fa[j + 1] = mf[i + 1]; fa[j + 2] = mf[i + 2]; }
                    glUseProgram(_pMapFace); glUniform1i(glGetUniformLocation(_pMapFace, "uFlat"), 1);
                    glUniform3f(glGetUniformLocation(_pMapFace, "uCol"), R(MapMarkInk), G(MapMarkInk), B(MapMarkInk)); glUniform1f(glGetUniformLocation(_pMapFace, "uK"), 0.45f * markK);
                    glUniform4f(glGetUniformLocation(_pMapFace, "uWave"), 1f, 0.35f, 0f, 0f);      // (the marks do not wave)
                    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                    glBindVertexArray(_mkfVao); glBindBuffer(GL_ARRAY_BUFFER, _mkfVbo); glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)fa.Length * 4), fa, GL_STREAM_DRAW);
                    glDrawArrays(GL_TRIANGLES, 0, fa.Length / 6);
                    glUniform1i(glGetUniformLocation(_pMapFace, "uFlat"), 0);
                }
                if (ml.Count > 0)
                {
                    glUseProgram(_pMapLine); glBlendFunc(GL_ONE, GL_ONE);
                    glUniform4f(glGetUniformLocation(_pMapLine, "uWave"), 1f, 0.35f, 0f, 0f);
                    var la = ml.ToArray();
                    glBindVertexArray(_mkVao); glBindBuffer(GL_ARRAY_BUFFER, _mkVbo); glBufferDataF(GL_ARRAY_BUFFER, new IntPtr((long)la.Length * 4), la, GL_STREAM_DRAW);
                    int n = la.Length / XSTRIDE;
                    glUniform3f(uCol, R(MapMarkInk), G(MapMarkInk), B(MapMarkInk)); glUniform1f(uW, MapHalo * 1.3f * res); glUniform1f(uK, 0.35f * markK); glUniform1i(uC, 0); glDrawArrays(GL_TRIANGLES, 0, n);
                    glUniform3f(uCol, R(MapMarkHot), G(MapMarkHot), B(MapMarkHot)); glUniform1f(uW, MapCore * 1.6f * res); glUniform1f(uK, markK); glUniform1i(uC, 1); glDrawArrays(GL_TRIANGLES, 0, n);
                }
            }
            // back to the picture's own state (reversed depth)
            glDisable(GL_BLEND); glDepthMask(1); glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glClearDepth(0.0); glBindVertexArray(0);
            Check("the map");
            LastMapMs = sw.Elapsed.TotalMilliseconds;
        }

        // ---- A GHOST (Josh, 2026-10-11, WELLROOM: Niamh, the floating lady -- "more ethereal ... transparent ghost-like ...
        // look like a ghost and not a bunch of polygons") --------------------------------------------------------------------
        // The characters a room's "ghost" block names (their textures carry Tex.Ghost) are left out of the room's own pass,
        // its shadow views and its reflections, and drawn here as glowing smoke over the picture:
        //   1. her SHAPE, at half size: how thick she is along each ray (nearest and farthest surface, max-blended) and the
        //      colours of her nearest surface -- both hidden behind the room by its depth;
        //   2. the LAYER: thin at her outline, fuller through her body (1 - exp(-density x thickness)); whole above GhostFadeHigh
        //      of her height, gone below GhostFadeLow; 3D smoke drifting up through her, eating her outline; her painted face
        //      and dress as light and shade in the glow's colour; a brighter rim where she is thin;
        //   3. a SOFT copy (a Gaussian blur GhostSoft of her height across) for the glow, so no polygon edge survives;
        //   4. laid over the picture -- a share of the sharp layer (GhostCore: her face stays readable) and the soft one --
        //      with the room behind her wobbling as through heat haze (GhostShimmer pixels at 1080 rows), and the fog cleared
        //      over her (the picture's alpha: what the placed lights light comes through the dark).
        // Her own faint light (AddGhostLight) goes with her: one more placed light, no shadows. Every size is a share of HER
        // HEIGHT as she stands in the room (her size is the engine's). The processor's picture (F9) draws her as before.
        public bool GhostOn;
        public int GhostColor = 0xBFF6F0, GhostRimColor = 0xE6FFFF;
        /// <summary>How much of her painted art shows as light and shade (0 = one even glow), the most opaque she gets, how
        /// fast she thickens (per her height of thickness), the thinnest she counts as (a single cloth panel), the rim.</summary>
        public float GhostTexture = 0.55f, GhostOpacity = 0.6f, GhostDensity = 8f, GhostMinThick = 0.01f, GhostRim = 1f;
        /// <summary>How brightly she glows against how much of the room she hides (1 = as much light as she hides).</summary>
        public float GhostBright = 1.8f;
        /// <summary>HER TEXTURES (Josh, 2026-10-11): how much of her own painted colours shows inside the glow, at the picture's
        /// full detail (0 = the glow's colour with her art's light and shade only, 1 = her art's colours).</summary>
        public float GhostTexColour = 0f;
        /// <summary>The glow's blur (share of her height), and the sharp layer's and the soft glow's shares over the picture.</summary>
        public float GhostSoft = 0.02f, GhostCore = 0.6f, GhostGlow = 0.8f;
        /// <summary>Height shares: nothing of her below Low, all of her above High.</summary>
        public float GhostFadeLow = 0.02f, GhostFadeHigh = 0.72f;
        /// <summary>The smoke: how much it eats her outline (0..1), its size and how fast it rises (shares of her height, /s).</summary>
        public float GhostNoise = 0.7f, GhostNoiseSize = 0.12f, GhostNoiseRise = 0.06f;
        /// <summary>The heat-haze wobble behind her (pixels at 1080 rows) and her slow breathing (share of her glow).</summary>
        public float GhostShimmer = 3f, GhostBreath = 0.08f;
        /// <summary>Her light: strength (0 = none), reach (half as bright this many of her heights away), its part in the fog,
        /// how high in her it sits (share of her height), colour.</summary>
        public float GhostLight = 0.25f, GhostLightRange = 1f, GhostLightAir = 1.5f, GhostLightHeight = 0.8f; public int GhostLightColor = 0x8FE6DC;
        public int LastGhostTris; public bool LastGhostDrawn; public string GhostError;
        /// <summary>Her box this frame (world x0 y0 z0 x1 y1 z1).</summary>
        public readonly float[] GhostBox = new float[6];
        bool _ghostHave; int _nRoomLights;
        uint _pGhostGeo, _pGhostBuild, _pGhostBlur, _pGhostComp;
        uint _gThickFbo, _gThickTex, _gSurfFbo, _gSurfTex, _gSurfDepth, _gLayerFbo, _gLayerTex, _gBgFbo, _gBgTex, _gFullFbo, _gFullTex, _gFullDepth; int _gW, _gH;
        readonly uint[] _gBlurFbo = new uint[2], _gBlurTex = new uint[2];
        // her shape (VS_MAIN's corners): mode 0 = thickness (-nearest z, farthest z, covered), 1 = her nearest surface's colour
        const string FS_GHOST_GEO = @"#version 400 core
in vec2 vUv; in vec3 vView; in vec4 vTri; in float vLod; in vec3 vWorld;
uniform sampler2D uTex; uniform sampler2D uMask; uniform sampler2D uDepth;
uniform float uFlip, uNear; uniform vec2 uScale; uniform int uMode;
out vec4 oColor;
void main() {
    vec2 st = vec2(vUv.x, uFlip > 0.5 ? 1.0 - vUv.y : vUv.y);
    if (texture(uMask, st).r < 0.5 / 255.0) discard;        // palette index 0: a hole in her texture
    // behind the room (a wall or a pillar between her and the eye): the room's depth is near / z, greater = nearer
    ivec2 q = clamp(ivec2(gl_FragCoord.xy * uScale), ivec2(0), textureSize(uDepth, 0) - 1);
    if (texelFetch(uDepth, q, 0).r > uNear / max(vView.z, 1e-3) * 1.0005) discard;
    if (uMode == 0) { oColor = vec4(-vView.z, vView.z, 1.0, 0.0); return; }
    oColor = vec4(texture(uTex, st).rgb, 1.0);
}";
        // the layer: premultiplied glow, alpha = how much of the room she hides
        const string FS_GHOST_BUILD = @"#version 400 core
uniform sampler2D uThick, uSurf; uniform vec2 uScale, uCentre; uniform float uFpx; uniform mat4 uCamWorld;
uniform vec2 uBoxY; uniform vec3 uCol, uRimCol;
uniform float uTexK, uOpacity, uDensity, uMinThick, uRim, uTime, uBreath, uBright, uTexCol;
uniform vec2 uFade; uniform vec3 uNoise;
out vec4 oColor;
" + NOISE_GLSL + @"
float fbm(vec3 p) { float s = 0.0, a = 0.5; for (int o = 0; o < 3; o++) { s += a * noised(p).x; p = p * 2.03 + vec3(1.7, 9.2, 3.1); a *= 0.5; } return s; }
void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    vec4 th = texelFetch(uThick, p, 0);
    if (th.b <= 0.0) { oColor = vec4(0.0); return; }
    float hg = max(uBoxY.y - uBoxY.x, 1.0);
    float zn = -th.r, thick = max(th.g - zn, uMinThick * hg) / hg;
    // her nearest surface, back in the room
    vec2 fc = (vec2(p) + 0.5) * uScale;
    vec3 Vv = vec3((fc.x - uCentre.x) / uFpx * zn, (uCentre.y - fc.y) / uFpx * zn, zn);
    vec3 P = (uCamWorld * vec4(Vv, 1.0)).xyz;
    float h = clamp((P.y - uBoxY.x) / hg, 0.0, 1.0);
    // smoke drifting up through her (its size and speed in shares of her height)
    float sz = max(uNoise.y * hg, 0.5);
    float n = clamp(0.5 + 1.2 * fbm((P - vec3(0.0, uTime * uNoise.z * hg, 0.0)) / sz), 0.0, 1.0);
    float fade = smoothstep(uFade.x, uFade.y, h + (n - 0.5) * 0.3 * uNoise.x);      // (its edge wisps too)
    float dens = 1.0 - exp(-uDensity * thick), edge = 1.0 - dens;
    float wisp = smoothstep(0.15, 0.85, n);
    float body = fade * mix(1.0, wisp, uNoise.x * edge);                           // the outline breaks into smoke, the middle holds
    body *= mix(1.0, 0.75 + 0.5 * wisp, 0.5 * uNoise.x);                          // and the smoke moves inside her too (gently)
    // her painted face and dress as light and shade in the glow -- or in her own colours (uTexCol) -- the smoke's swirls brighter
    vec3 sc = texelFetch(uSurf, p, 0).rgb;
    float tl = dot(sc, vec3(0.30, 0.59, 0.11));
    vec3 base = mix(uCol * mix(1.0, 0.5 + 0.8 * tl, uTexK), sc, uTexCol) * (0.85 + 0.3 * n);
    float a = clamp(uOpacity * uBreath * (0.3 + 0.7 * dens) * body, 0.0, 1.0);
    // where she is thin (a cloth panel, an outline) the rim's colour, glowing without hiding anything
    vec3 rim = uRimCol * (uRim * uBreath * edge * edge * fade * mix(1.0, wisp, 0.5 * uNoise.x));
    // (premultiplied: she glows more brightly than she hides -- uBright)
    oColor = vec4(base * a * uBright + rim * 0.3 * a, a);
}";
        const string FS_GHOST_BLUR = @"#version 400 core
uniform sampler2D uSrc; uniform ivec2 uDir; uniform float uSigma; uniform int uR;
out vec4 oColor;
void main() {
    ivec2 p = ivec2(gl_FragCoord.xy), mx = textureSize(uSrc, 0) - 1;
    vec4 s = vec4(0.0); float ws = 0.0, k = -0.5 / (uSigma * uSigma);
    for (int i = -uR; i <= uR; i++) {
        float w = exp(float(i * i) * k);
        s += w * texelFetch(uSrc, clamp(p + uDir * i, ivec2(0), mx), 0); ws += w;
    }
    oColor = s / ws;
}";
        // over the picture: the room behind her (wobbling), the sharp layer's share, the soft glow; alpha = the fog cleared
        const string FS_GHOST_COMP = @"#version 400 core
uniform sampler2D uBg, uLayer, uSoft; uniform vec2 uSize, uTexel; uniform float uTime, uShimmer, uCore, uGlow, uRim, uReach;
// her own colours at the picture's full size (her nearest surface; alpha 1 where she is), and how much of them shows
uniform sampler2D uFull; uniform float uTexCol, uBright;
out vec4 oColor;
" + NOISE_GLSL + @"
void main() {
    vec2 fc = gl_FragCoord.xy, uv = fc / uSize;
    // the sharp layer a little softened (3 x 3 taps a half-size texel apart): no stair-stepped outline survives
    vec4 sharp = vec4(0.0);
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) sharp += texture(uLayer, uv + vec2(i, j) * uTexel) * (float(2 - abs(i)) * float(2 - abs(j)) / 16.0);
    vec4 soft = texture(uSoft, uv);
    float m = clamp(soft.a * 2.5 + sharp.a, 0.0, 1.0);
    vec2 o = vec2(0.0);
    if (m > 0.002 && uShimmer > 0.0) {
        vec3 q = vec3(fc / (uSize.y * 0.025), uTime * 0.7);
        o = vec2(noised(q).x, noised(q + vec3(31.7, 11.3, 5.1)).x) * (uShimmer * m);
    }
    vec3 bg = texture(uBg, (fc + o) / uSize).rgb;
    float here = texelFetch(uBg, ivec2(fc), 0).a;
    // the sharp layer only well inside her outline -- where the soft copy holds most of it -- so no polygon edge shows;
    // toward the outline she is the glow alone
    // how far inside her: the soft copy's alpha against the fullest of her near here (eight taps a glow's width out) --
    // 1 deep inside, a half at her outline, toward 0 past it, whatever her thickness there
    float A = sharp.a;
    for (int k = 0; k < 8; k++) { float an = float(k) * 0.785398; A = max(A, texture(uLayer, uv + vec2(cos(an), sin(an)) * uReach * uTexel).a); }
    float r = A > 1e-3 ? clamp(soft.a / A, 0.0, 1.0) : 0.0;
    float core = uCore * smoothstep(0.3, 0.65, r);
    // HER TEXTURES (Josh, 2026-10-11: 'add back her textures but leave the new effects'): inside her, her painted colours
    // at full detail, as see-through as the layer there (its alpha carries the fade and the smoke)
    vec4 tf = texelFetch(uFull, ivec2(fc), 0);
    vec3 coreC = mix(sharp.rgb, tf.rgb * sharp.a * uBright, uTexCol * tf.a);
    // the glow brighter toward her outline and past it (her rim, as light in the air round her)
    vec3 L = coreC * core + soft.rgb * (uGlow * (1.0 + uRim * (1.0 - r)));
    float a = clamp(sharp.a * core + soft.a * uGlow * 0.7, 0.0, 0.95);
    // her light SCREENED over what shows through her (never past white: over a torch-lit wall she stays a pale shape)
    vec3 c = bg * (1.0 - a);
    oColor = vec4(1.0 - (1.0 - c) * (1.0 - min(L, vec3(1.0))), max(here, 0.9 * m));
}";
        /// <summary>Where the ghost is this frame: the box round her triangles (those whose texture is a ghost's).</summary>
        void GhostBounds(float[] vx, int[] idx, int[] triTex, Raster.Tex[] texes)
        {
            _ghostHave = false; LastGhostTris = 0;
            if (!GhostOn) return;
            float x0 = float.MaxValue, y0 = float.MaxValue, z0 = float.MaxValue, x1 = float.MinValue, y1 = float.MinValue, z1 = float.MinValue;
            int n = 0, nTri = idx.Length / 3, nt = texes.Length;
            for (int t = 0; t < nTri; t++)
            {
                int ti = triTex[t]; if (ti < 0 || ti >= nt || texes[ti] == null || !texes[ti].Ghost) continue;
                for (int k = 0; k < 3; k++)
                {
                    int v = idx[t * 3 + k] * 3; float x = vx[v], y = vx[v + 1], z = vx[v + 2];
                    if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; if (z < z0) z0 = z; if (z > z1) z1 = z;
                }
                n++;
            }
            LastGhostTris = n;
            if (n == 0 || y1 - y0 < 0.5f) return;
            GhostBox[0] = x0; GhostBox[1] = y0; GhostBox[2] = z0; GhostBox[3] = x1; GhostBox[4] = y1; GhostBox[5] = z1;
            _ghostHave = true;
        }
        /// <summary>Her faint light, one more placed light (all round, no shadows) at GhostLightHeight of her, breathing with her.</summary>
        void AddGhostLight()
        {
            if (!GhostOn || !_ghostHave || GhostLight <= 0f || _nLights >= Raster.MaxLights) return;
            int i = _nLights, b = i * 8; float hgt = GhostBox[4] - GhostBox[1];
            float k = GhostLight * (1f - GhostBreath * 0.5f * (1f - (float)Math.Sin(Time * 1.1)));
            _lightsW[b] = (GhostBox[0] + GhostBox[3]) * 0.5f; _lightsW[b + 1] = GhostBox[1] + hgt * GhostLightHeight; _lightsW[b + 2] = (GhostBox[2] + GhostBox[5]) * 0.5f;
            _lightsW[b + 3] = ((GhostLightColor >> 16) & 255) / 255f * k; _lightsW[b + 4] = ((GhostLightColor >> 8) & 255) / 255f * k; _lightsW[b + 5] = (GhostLightColor & 255) / 255f * k;
            _lightsW[b + 6] = Math.Max(10f, GhostLightRange * hgt); _lightsW[b + 7] = 0f;
            SetLightSpot(i, 0f, -1f, 0f, 0f, 0f, GhostLightAir, 0f, 0f); SetLightTint(i, 1f, 1f, 1f, 0f, 1f); _airFirst[i] = false;
            _nLights++;
        }
        void DrawGhost(Raster.Tex[] texes, bool flipV)
        {
            try { LastGhostDrawn = GhostPasses(texes, flipV); }
            catch (Exception e) { GhostError = e.Message; GhostOn = false; while (glGetError() != 0) { } }       // (she is drawn as before from the next frame)
            finally
            {
                // as the passes after this one expect
                glDisable(GL_SCISSOR_TEST); glDisable(GL_BLEND); if (glBlendEquation != null) glBlendEquation(GL_FUNC_ADD);
                glColorMask(1, 1, 1, 1); glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(1);
                glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H); glActiveTexture(GL_TEXTURE0); glBindVertexArray(0);
            }
        }
        bool GhostPasses(Raster.Tex[] texes, bool flipV)
        {
            if (glBlendEquation == null) throw new InvalidOperationException("the graphics driver has no glBlendEquation");
            if (_pGhostGeo == 0)
            {
                _pGhostGeo = Link(VS_MAIN, FS_GHOST_GEO, "the ghost's shape");
                _pGhostBuild = Link(VS_CLEAR, FS_GHOST_BUILD, "the ghost's smoke");
                _pGhostBlur = Link(VS_CLEAR, FS_GHOST_BLUR, "the ghost's glow");
                _pGhostComp = Link(VS_CLEAR, FS_GHOST_COMP, "the ghost over the picture");
            }
            EnsureGhostTargets();
            float hgt = GhostBox[4] - GhostBox[1];
            // where she is on the screen (her box's corners) and how far away
            float[] V = _view; float fpx = FocalPx, cy = VHf * 0.5f;
            float sx0 = float.MaxValue, sy0 = float.MaxValue, sx1 = float.MinValue, sy1 = float.MinValue; bool behind = false, seen = false;
            for (int c = 0; c < 8; c++)
            {
                float x = GhostBox[(c & 1) != 0 ? 3 : 0], y = GhostBox[(c & 2) != 0 ? 4 : 1], z = GhostBox[(c & 4) != 0 ? 5 : 2];
                float ex = x * V[0] + y * V[4] + z * V[8] + V[12], ey = x * V[1] + y * V[5] + z * V[9] + V[13], ez = x * V[2] + y * V[6] + z * V[10] + V[14];
                if (ez < NearZ * 4f) { behind = true; continue; }
                seen = true;
                float px = W * 0.5f + ex * fpx / ez, py = cy - ey * fpx / ez;
                sx0 = Math.Min(sx0, px); sx1 = Math.Max(sx1, px); sy0 = Math.Min(sy0, py); sy1 = Math.Max(sy1, py);
            }
            if (!seen) return false;
            float mx = (GhostBox[0] + GhostBox[3]) * 0.5f, my = (GhostBox[1] + GhostBox[4]) * 0.5f, mz = (GhostBox[2] + GhostBox[5]) * 0.5f;
            float zc = Math.Max(NearZ * 4f, mx * V[2] + my * V[6] + mz * V[10] + V[14]);
            float sigma = Math.Max(0.5f, Math.Min(16f, GhostSoft * hgt * fpx / zc * 0.5f));      // (pixels at half size)
            int rad = Math.Min(40, (int)Math.Ceiling(sigma * 2.5f));
            float shim = Math.Max(0f, GhostShimmer) * H / 1080f;
            int margin = (int)(rad * 2 + shim + 8);
            int rx0 = 0, ry0 = 0, rx1 = W, ry1 = H;
            if (!behind)
            {
                if (sx1 < -margin || sy1 < -margin || sx0 > W + margin || sy0 > H + margin) return false;
                rx0 = Math.Max(0, (int)Math.Floor(sx0) - margin); ry0 = Math.Max(0, (int)Math.Floor(sy0) - margin);
                rx1 = Math.Min(W, (int)Math.Ceiling(sx1) + margin); ry1 = Math.Min(H, (int)Math.Ceiling(sy1) + margin);
            }
            if (rx1 - rx0 < 2 || ry1 - ry0 < 2) return false;
            int hx0 = rx0 / 2, hy0 = ry0 / 2, hx1 = Math.Min(_gW, rx1 / 2 + 2), hy1 = Math.Min(_gH, ry1 / 2 + 2);
            float scX = (float)W / _gW, scY = (float)H / _gH;

            // 1. HER SHAPE, half size, in her box only
            glDisable(GL_CULL_FACE); glDisable(GL_STENCIL_TEST); glColorMask(1, 1, 1, 1);
            uint pg = _pGhostGeo; Func<string, int> L = s => glGetUniformLocation(pg, s);
            glUseProgram(pg);
            glUniformMatrix4fv(L("uView"), 1, 0, _view);
            glUniform2f(L("uF"), _focal * VHf / W, _focal * VHf / H); glUniform1f(L("uOffY"), OffY); glUniform1f(L("uNear"), NearZ);
            glUniform1f(L("uFlip"), flipV ? 1f : 0f); glUniform2f(L("uScale"), scX, scY);
            glUniform1i(L("uTex"), 0); glUniform1i(L("uMask"), 1); glUniform1i(L("uDepth"), 2);
            glActiveTexture(GL_TEXTURE0 + 2); glBindTexture(GL_TEXTURE_2D, _depthTex);
            glEnable(GL_SCISSOR_TEST); glScissor(hx0, hy0, hx1 - hx0, hy1 - hy0);
            glBindVertexArray(_main.Vao);
            //    a. how thick: the nearest and the farthest of her surfaces along each ray, every face counted
            glBindFramebuffer(GL_FRAMEBUFFER, _gThickFbo); glViewport(0, 0, _gW, _gH);
            glClearColor(-60000f, 0f, 0f, 0f); glClear(GL_COLOR_BUFFER_BIT);
            glDisable(GL_DEPTH_TEST); glDepthMask(0);
            glEnable(GL_BLEND); glBlendEquation(GL_MAX); glBlendFunc(GL_ONE, GL_ONE);
            glUniform1i(L("uMode"), 0); GhostBatches(texes);
            glDisable(GL_BLEND); glBlendEquation(GL_FUNC_ADD);
            //    b. the colours of her nearest surface
            glBindFramebuffer(GL_FRAMEBUFFER, _gSurfFbo);
            glClearColor(0f, 0f, 0f, 0f); glClearDepth(0.0); glDepthMask(1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER);
            glUniform1i(L("uMode"), 1); GhostBatches(texes);
            //    c. her own colours at full size, for her textures inside the glow (GhostTexColour)
            bool full = GhostTexColour > 0f;
            if (full)
            {
                EnsureGhostFull();
                glBindFramebuffer(GL_FRAMEBUFFER, _gFullFbo); glViewport(0, 0, W, H); glScissor(rx0, ry0, rx1 - rx0, ry1 - ry0);
                glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
                glUniform2f(L("uScale"), 1f, 1f); GhostBatches(texes); glUniform2f(L("uScale"), scX, scY);
                glViewport(0, 0, _gW, _gH); glScissor(hx0, hy0, hx1 - hx0, hy1 - hy0);
            }
            glDisable(GL_DEPTH_TEST); glDepthMask(0);

            // 2. THE LAYER (the glow and blur pictures cleared whole: the blur reads past her box)
            glBindVertexArray(_eVao);
            glDisable(GL_SCISSOR_TEST);
            glBindFramebuffer(GL_FRAMEBUFFER, _gLayerFbo); glClear(GL_COLOR_BUFFER_BIT);
            for (int k = 0; k < 2; k++) { glBindFramebuffer(GL_FRAMEBUFFER, _gBlurFbo[k]); glClear(GL_COLOR_BUFFER_BIT); }
            glEnable(GL_SCISSOR_TEST);
            glBindFramebuffer(GL_FRAMEBUFFER, _gLayerFbo);
            uint pb = _pGhostBuild; Func<string, int> B = s => glGetUniformLocation(pb, s);
            glUseProgram(pb);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _gThickTex);
            glActiveTexture(GL_TEXTURE0 + 1); glBindTexture(GL_TEXTURE_2D, _gSurfTex);
            glUniform1i(B("uThick"), 0); glUniform1i(B("uSurf"), 1);
            glUniform2f(B("uScale"), scX, scY); glUniform2f(B("uCentre"), W * 0.5f, cy); glUniform1f(B("uFpx"), fpx);
            glUniformMatrix4fv(B("uCamWorld"), 1, 0, _camWorld);
            glUniform2f(B("uBoxY"), GhostBox[1], GhostBox[4]);
            glUniform3f(B("uCol"), ((GhostColor >> 16) & 255) / 255f, ((GhostColor >> 8) & 255) / 255f, (GhostColor & 255) / 255f);
            glUniform3f(B("uRimCol"), ((GhostRimColor >> 16) & 255) / 255f, ((GhostRimColor >> 8) & 255) / 255f, (GhostRimColor & 255) / 255f);
            glUniform1f(B("uTexK"), Math.Max(0f, Math.Min(1f, GhostTexture))); glUniform1f(B("uOpacity"), Math.Max(0f, Math.Min(1f, GhostOpacity)));
            glUniform1f(B("uDensity"), Math.Max(0f, GhostDensity)); glUniform1f(B("uMinThick"), Math.Max(0.001f, GhostMinThick)); glUniform1f(B("uRim"), Math.Max(0f, GhostRim));
            glUniform1f(B("uTime"), Time); glUniform1f(B("uBreath"), 1f - GhostBreath * 0.5f * (1f - (float)Math.Sin(Time * 1.1))); glUniform1f(B("uBright"), Math.Max(0f, GhostBright));
            glUniform1f(B("uTexCol"), Math.Max(0f, Math.Min(1f, GhostTexColour)));
            glUniform2f(B("uFade"), GhostFadeLow, Math.Max(GhostFadeLow + 0.01f, GhostFadeHigh));
            glUniform3f(B("uNoise"), Math.Max(0f, Math.Min(1f, GhostNoise)), Math.Max(0.01f, GhostNoiseSize), GhostNoiseRise);
            glDrawArrays(GL_TRIANGLES, 0, 3);

            // 3. THE SOFT COPY: across, then down
            uint pu = _pGhostBlur; Func<string, int> U = s => glGetUniformLocation(pu, s);
            glUseProgram(pu);
            glUniform1f(U("uSigma"), sigma); glUniform1i(U("uR"), rad); glUniform1i(U("uSrc"), 0);
            glActiveTexture(GL_TEXTURE0);
            glBindFramebuffer(GL_FRAMEBUFFER, _gBlurFbo[0]); glBindTexture(GL_TEXTURE_2D, _gLayerTex); glUniform2i(U("uDir"), 1, 0); glDrawArrays(GL_TRIANGLES, 0, 3);
            glBindFramebuffer(GL_FRAMEBUFFER, _gBlurFbo[1]); glBindTexture(GL_TEXTURE_2D, _gBlurTex[0]); glUniform2i(U("uDir"), 0, 1); glDrawArrays(GL_TRIANGLES, 0, 3);

            // 4. OVER THE PICTURE: the picture as it stands copied out (her box), then she is laid over it
            glDisable(GL_SCISSOR_TEST);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, _fbo); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, _gBgFbo);
            glBlitFramebuffer(rx0, ry0, rx1, ry1, rx0, ry0, rx1, ry1, GL_COLOR_BUFFER_BIT, GL_NEAREST);
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, W, H);
            glEnable(GL_SCISSOR_TEST); glScissor(rx0, ry0, rx1 - rx0, ry1 - ry0);
            uint pc = _pGhostComp; Func<string, int> C = s => glGetUniformLocation(pc, s);
            glUseProgram(pc);
            glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _gBgTex);
            glActiveTexture(GL_TEXTURE0 + 1); glBindTexture(GL_TEXTURE_2D, _gLayerTex);
            glActiveTexture(GL_TEXTURE0 + 2); glBindTexture(GL_TEXTURE_2D, _gBlurTex[1]);
            glActiveTexture(GL_TEXTURE0 + 3); glBindTexture(GL_TEXTURE_2D, full ? _gFullTex : _gSurfTex);
            glUniform1i(C("uBg"), 0); glUniform1i(C("uLayer"), 1); glUniform1i(C("uSoft"), 2); glUniform1i(C("uFull"), 3);
            glUniform1f(C("uTexCol"), full ? Math.Min(1f, GhostTexColour) : 0f); glUniform1f(C("uBright"), Math.Max(0f, GhostBright));
            glUniform2f(C("uSize"), W, H); glUniform1f(C("uTime"), Time); glUniform1f(C("uShimmer"), shim);
            glUniform1f(C("uCore"), Math.Max(0f, GhostCore)); glUniform1f(C("uGlow"), Math.Max(0f, GhostGlow)); glUniform1f(C("uRim"), Math.Max(0f, GhostRim));
            glUniform2f(C("uTexel"), 1f / _gW, 1f / _gH);
            glUniform1f(C("uReach"), sigma * 2f);         // (half-size texels: two of the glow's sigmas)
            glDrawArrays(GL_TRIANGLES, 0, 3);
            Check("drawing the ghost");
            return true;
        }
        void GhostBatches(Raster.Tex[] texes)
        {
            var s = _main;
            for (int i = 0; i < s.Nt && i < texes.Length; i++)
            {
                if (s.Count[i] == 0 || texes[i] == null || !texes[i].Ghost) continue;
                GTex g; if (!_tex.TryGetValue(texes[i], out g)) continue;
                glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, g.Rgb);
                glActiveTexture(GL_TEXTURE0 + 1); glBindTexture(GL_TEXTURE_2D, g.Mask);
                glDrawArrays(GL_TRIANGLES, s.Start[i] * 3, s.Count[i] * 3);
            }
            glActiveTexture(GL_TEXTURE0);
        }
        void EnsureGhostTargets()
        {
            if (_gThickTex != 0) return;
            _gW = (W + 1) / 2; _gH = (H + 1) / 2;
            _gThickTex = GhostTex(_gW, _gH, GL_RGBA16F, GL_RGBA, GL_FLOAT, false); _gThickFbo = GhostFbo(_gThickTex, 0, "the ghost's thickness");
            _gSurfTex = GhostTex(_gW, _gH, GL_RGBA8, GL_BGRA, GL_UNSIGNED_BYTE, false); _gSurfDepth = GhostTex(_gW, _gH, GL_DEPTH_COMPONENT32F, GL_DEPTH_COMPONENT, GL_FLOAT, false);
            _gSurfFbo = GhostFbo(_gSurfTex, _gSurfDepth, "the ghost's colours");
            _gLayerTex = GhostTex(_gW, _gH, GL_RGBA16F, GL_RGBA, GL_FLOAT, true); _gLayerFbo = GhostFbo(_gLayerTex, 0, "the ghost's smoke");
            for (int k = 0; k < 2; k++) { _gBlurTex[k] = GhostTex(_gW, _gH, GL_RGBA16F, GL_RGBA, GL_FLOAT, true); _gBlurFbo[k] = GhostFbo(_gBlurTex[k], 0, "the ghost's glow"); }
            _gBgTex = GhostTex(W, H, GL_RGBA8, GL_BGRA, GL_UNSIGNED_BYTE, true); _gBgFbo = GhostFbo(_gBgTex, 0, "the picture behind the ghost");
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
        }
        // her colours at full size: made the first time a ghost asks for her textures
        void EnsureGhostFull()
        {
            if (_gFullTex != 0) return;
            _gFullTex = GhostTex(W, H, GL_RGBA8, GL_BGRA, GL_UNSIGNED_BYTE, false); _gFullDepth = GhostTex(W, H, GL_DEPTH_COMPONENT32F, GL_DEPTH_COMPONENT, GL_FLOAT, false);
            _gFullFbo = GhostFbo(_gFullTex, _gFullDepth, "the ghost's colours at full size");
        }
        uint GhostTex(int w, int h, uint ifmt, uint fmt, uint type, bool linear)
        {
            var ids = new uint[1]; glGenTextures(1, ids);
            glBindTexture(GL_TEXTURE_2D, ids[0]);
            glTexImage2DN(GL_TEXTURE_2D, 0, (int)ifmt, w, h, 0, fmt, type, IntPtr.Zero);
            int f = (int)(linear ? GL_LINEAR : GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, f); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, f);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, (int)GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, (int)GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
            return ids[0];
        }
        uint GhostFbo(uint colour, uint depth, string what)
        {
            var ids = new uint[1]; glGenFramebuffers(1, ids); glBindFramebuffer(GL_FRAMEBUFFER, ids[0]);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colour, 0);
            if (depth != 0) glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0);
            Complete(what);
            return ids[0];
        }
        public double LastFinishMs;
        public bool ReadPending { get { return _readPending; } }
        /// <summary>Finished pictures held back for a sudden black band (see FinishRead).</summary>
        public long HeldBlackFrames;
        float _prevBlackFrac = 1f; int _heldBlack;      // (1: nothing before the first picture to compare with)
        public void StartRead()
        {
            if (_readPbo == 0) { var ids = new uint[1]; glGenBuffers(1, ids); _readPbo = ids[0]; }
            glBindFramebuffer(GL_FRAMEBUFFER, _compFbo); glReadBuffer(GL_COLOR_ATTACHMENT0);
            glBindBuffer(GL_PIXEL_PACK_BUFFER, _readPbo);
            glBufferDataN(GL_PIXEL_PACK_BUFFER, new IntPtr((long)W * H * 4), IntPtr.Zero, GL_STREAM_READ);
            glReadPixelsN(0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, IntPtr.Zero);
            glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);        // (every other read passes its own array)
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
            Check("starting the read-back");
            _readPending = true;
        }
        /// <summary>The picture StartRead began, into `dst`; false if none was started.</summary>
        public bool FinishRead(int[] dst)
        {
            if (!_readPending) return false;
            if (dst == null || dst.Length < W * H) throw new ArgumentException("picture buffer too small");
            var sw = Stopwatch.StartNew();
            _readPending = false;
            glBindBuffer(GL_PIXEL_PACK_BUFFER, _readPbo);
            IntPtr src = glMapBufferRange(GL_PIXEL_PACK_BUFFER, IntPtr.Zero, new IntPtr((long)W * H * 4), GL_MAP_READ_BIT);
            bool ok = src != IntPtr.Zero;
            if (ok) { Marshal.Copy(src, dst, 0, W * H); glUnmapBuffer(GL_PIXEL_PACK_BUFFER); }
            glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
            Check("finishing the read-back");
            // FLICKER WATCH: a picture with a band of pure-black rows the one before did not have
            // is held back once (the window keeps the last one) and counted
            if (ok)
            {
                int rows = 0, black = 0;
                for (int y = 4; y < H; y += 8)
                {
                    rows++; int o = y * W; bool all = true;
                    for (int k = 0; k < 48 && all; k++) if ((dst[o + (int)((k + 0.5f) * W / 48f)] & 0xFFFFFF) != 0) all = false;
                    if (all) black++;
                }
                float frac = rows > 0 ? black / (float)rows : 0f;
                if (frac >= 0.15f && _prevBlackFrac < 0.05f && _heldBlack < 1) { _heldBlack++; HeldBlackFrames++; ok = false; }
                else { _heldBlack = 0; _prevBlackFrac = frac; }
            }
            LastFinishMs = sw.Elapsed.TotalMilliseconds;
            return ok;
        }
        /// <summary>Forget a started read (the picture went another way meanwhile).</summary>
        public void DropRead() { _readPending = false; }
        /// <summary>The finished picture (after PostCompose), 0x00RRGGBB, top row first.</summary>
        public void ReadComposed(int[] dst)
        {
            if (dst == null || dst.Length < W * H) throw new ArgumentException("picture buffer too small");
            var sw = Stopwatch.StartNew();
            glBindFramebuffer(GL_FRAMEBUFFER, _compFbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glReadPixels(0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, dst);
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
            Check("reading the finished picture back");
            LastReadMs = sw.Elapsed.TotalMilliseconds;
        }
        /// <summary>The finished picture, 0x00RRGGBB, top row first: the shape of Raster.Color32.
        /// Waits for the card to finish.</summary>
        public void ReadBack(int[] dst)
        {
            if (dst == null || dst.Length < W * H) throw new ArgumentException("picture buffer too small");
            var sw = Stopwatch.StartNew();
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glReadPixels(0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, dst);
            Check("reading the picture back");
            LastReadMs = sw.Elapsed.TotalMilliseconds;
        }

        /// <summary>The depth of every pixel, top row first, in Raster's own terms: 1/z (0 = nothing
        /// drawn). The card holds near/z, so it is divided back out here.</summary>
        public void ReadDepth(float[] dst)
        {
            if (dst == null || dst.Length < W * H) throw new ArgumentException("depth buffer too small");
            glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
            glReadPixelsF(0, 0, W, H, GL_DEPTH_COMPONENT, GL_FLOAT, dst);
            Check("reading the depth back");
            float k = 1f / NearZ;
            for (int i = 0; i < W * H; i++) dst[i] *= k;
        }

        /// <summary>Wait for the card (for timing what the drawing itself costs).</summary>
        public void Finish() { glFinish(); }

        public void Dispose()
        {
            try
            {
                if (_rc != IntPtr.Zero)
                {
                    wglMakeCurrent(_dc, _rc);
                    try { ForgetTextures(); } catch { }
                    try
                    {
                        foreach (var p in new[] { _pMain, _pDepth, _pClear, _pMote }) if (p != 0) glDeleteProgram(p);
                        foreach (var s in new[] { _main, _mirror }) if (s != null) { glDeleteBuffers(1, new[] { s.Vbo }); glDeleteVertexArrays(1, new[] { s.Vao }); }
                        if (_wVbo != 0) glDeleteBuffers(2, new[] { _wVbo, _mVbo });
                        if (_wVao != 0) glDeleteVertexArrays(3, new[] { _wVao, _mVao, _eVao });
                        foreach (var s in _slots) if (s != null) { glDeleteTextures(1, new[] { s.Tex }); glDeleteFramebuffers(1, new[] { s.Fbo }); }
                        if (_depthTex != 0) glDeleteTextures(2, new[] { _depthTex, _surfTex });
                        if (_fbo != 0) glDeleteFramebuffers(2, new[] { _fbo, _surfFbo });
                        foreach (var p in new[] { _pSharp, _pComp, _pNorm, _pPart, _pWater, _pPresent, _pHolo, _pFlame, _pXray }) if (p != 0) glDeleteProgram(p);
                        foreach (var tx in new[] { _shadeTex, _picTex, _volTex }) if (tx != 0) glDeleteTextures(1, new[] { tx });
                        if (_volFbo != 0) glDeleteFramebuffers(1, new[] { _volFbo });
                        DetachPresent();
                        if (_reflFbo != 0) { glDeleteFramebuffers(1, new[] { _reflFbo }); glDeleteTextures(1, new[] { _reflTex }); }
                        if (_pVbo != 0) { glDeleteBuffers(1, new[] { _pVbo }); glDeleteVertexArrays(1, new[] { _pVao }); }
                        if (_normFbo != 0) glDeleteFramebuffers(1, new[] { _normFbo });
                        foreach (var t in new[] { _colorTex, _postTex, _compTex, _screenTex, _mapTex }) if (t != 0) glDeleteTextures(1, new[] { t });
                        if (_screenPbo != 0) glDeleteBuffers(1, new[] { _screenPbo });
                        if (_readPbo != 0) glDeleteBuffers(1, new[] { _readPbo });
                        if (_postFbo != 0) glDeleteFramebuffers(2, new[] { _postFbo, _compFbo });
                    }
                    catch { }
                    wglMakeCurrent(IntPtr.Zero, IntPtr.Zero); wglDeleteContext(_rc); _rc = IntPtr.Zero;
                }
            }
            finally
            {
                if (_dc != IntPtr.Zero) { ReleaseDC(_hwnd, _dc); _dc = IntPtr.Zero; }
                if (_hwnd != IntPtr.Zero) { DestroyWindow(_hwnd); _hwnd = IntPtr.Zero; }
            }
        }
    }

    // ---- THE PLACED LIGHTS, EVERY FRAME (2026-10-13 performance audit) ------------------------------
    // Update-RoomLights (the watcher) worked out each placed light's flicker, its dancing point and its
    // cycling colour in script, a few dozen property reads and Math calls per light per frame; the
    // shadow views' loop after it read them back. The same maths, in the same order and the same
    // precision (doubles, cast to float where the script cast), now runs here from a copy of the
    // room's lights made once per room. STILL EVERY FRAME: throttled, the flicker and the dancing
    // shadows would visibly step. [[azrael-atmosphere]] [[azrael-perf-audit]]
    public class RoomLightSet
    {
        public sealed class L
        {
            public float X, Y, Z, Range;
            public double R, G, B, Power, Flicker, Phase, Dance, CycleSec, CycleOff;
            public int[] Cycle;            // null = a steady colour
            public double[] Dir;           // null = no direction (no shadow view)
            public double Noise, Jx, Jy, Jz;   // per-frame state
        }
        public readonly List<L> Lights = new List<L>();
        /// <summary>Each light's shadow-view raster (null where it casts none), as Set-RoomAtmosphere made them.</summary>
        public Raster[] Views;
        readonly Random _rnd;
        public RoomLightSet() { _rnd = new Random(); }
        /// <summary>A fixed seed: for checking against the script's maths (the same Random, the same jitter).</summary>
        public RoomLightSet(int seed) { _rnd = new Random(seed); }

        public void Add(float x, float y, float z, double r, double g, double b, double power, float range, double flicker, double phase, double dance, int[] cycle, double cycleSec, double cycleOff, double[] dir)
        {
            Lights.Add(new L { X = x, Y = y, Z = z, R = r, G = g, B = b, Power = power, Range = range, Flicker = flicker, Phase = phase, Dance = dance, Cycle = cycle, CycleSec = cycleSec, CycleOff = cycleOff, Dir = (dir != null && dir.Length == 3) ? dir : null });
        }
        public int Count { get { return Lights.Count; } }
        public double JitterX(int i) { return Lights[i].Jx; }
        public double JitterY(int i) { return Lights[i].Jy; }
        public double JitterZ(int i) { return Lights[i].Jz; }

        /// <summary>This frame's strength, colour and position of every light into ras.Lights (8 floats
        /// each) and ras.LightCount; the bounced light's flicker into gpu.GiFlicker when it is on.</summary>
        public void Update(Raster ras, double t, GpuRaster gpu)
        {
            int n = Lights.Count; ras.LightCount = 0;
            if (n == 0) return;
            float[] o = ras.Lights;
            for (int i = 0; i < n; i++)
            {
                L l = Lights[i];
                // a torch: two slow sways and a little jitter, never below about half strength
                l.Noise = 0.7 * l.Noise + 0.3 * (_rnd.NextDouble() - 0.5);
                double f = 1.0 + l.Flicker * (0.55 * Math.Sin(t * 7.9 + l.Phase) + 0.3 * Math.Sin(t * 19.3 + l.Phase * 2.1) + 1.2 * l.Noise);
                if (f < 0.45) f = 0.45;
                double p = l.Power * f; int b = i * 8;
                // DANCING SHADOWS: the light's point wanders round the flame, and up when it flares
                double amp = l.Flicker > 0 ? l.Dance : 0;
                if (amp > 0)
                {
                    l.Jx = amp * (0.5 * Math.Sin(t * 5.3 + l.Phase) + 0.3 * Math.Sin(t * 12.7 + l.Phase * 1.9) + 0.4 * l.Noise);
                    l.Jz = amp * (0.5 * Math.Sin(t * 4.6 + l.Phase * 2.7) + 0.3 * Math.Sin(t * 11.3 + l.Phase * 0.7) - 0.4 * l.Noise);
                    l.Jy = amp * 0.6 * Math.Max(-1.0, Math.Min(1.5, (f - 1.0) / l.Flicker));
                }
                else { l.Jx = 0.0; l.Jy = 0.0; l.Jz = 0.0; }
                o[b] = (float)(l.X + l.Jx); o[b + 1] = (float)(l.Y + l.Jy); o[b + 2] = (float)(l.Z + l.Jz);
                double cr = l.R, cg = l.G, cb = l.B;
                if (l.Cycle != null)
                {
                    // its colour round the loop: which two colours it is between, eased (smoothstep) from one to the next
                    int nc = l.Cycle.Length; double u = ((t / Math.Max(1.0, l.CycleSec) + l.CycleOff) % 1.0) * nc;
                    int k0 = ((int)Math.Floor(u)) % nc, k1 = (k0 + 1) % nc;
                    double mixK = u - Math.Floor(u); mixK = mixK * mixK * (3 - 2 * mixK); int c0 = l.Cycle[k0], c1 = l.Cycle[k1];
                    cr = ((1 - mixK) * ((c0 >> 16) & 255) + mixK * ((c1 >> 16) & 255)) / 255.0;
                    cg = ((1 - mixK) * ((c0 >> 8) & 255) + mixK * ((c1 >> 8) & 255)) / 255.0;
                    cb = ((1 - mixK) * (c0 & 255) + mixK * (c1 & 255)) / 255.0;
                }
                o[b + 3] = (float)(cr * p); o[b + 4] = (float)(cg * p); o[b + 5] = (float)(cb * p); o[b + 6] = l.Range;
            }
            ras.LightCount = n;
            if (gpu != null && gpu.GiOn)
            {
                double sw = 0.0, sf = 0.0;
                for (int i = 0; i < n; i++)
                {
                    L l = Lights[i]; double pw = l.Power * (l.R + l.G + l.B); sw += pw;
                    sf += pw * ((double)o[i * 8 + 3] + (double)o[i * 8 + 4] + (double)o[i * 8 + 5]) / Math.Max(1e-6, l.Power * (l.R + l.G + l.B));
                }
                gpu.GiFlicker = (float)(sw > 0 ? sf / sw : 1);
            }
        }

        /// <summary>Aim light li's shadow view from where it is this frame (it dances), looking the way
        /// it faces; the view's raster, or null for a light with none.</summary>
        public Raster AimView(int li, out float x, out float y, out float z)
        {
            x = y = z = 0;
            Raster lz = (Views != null && li < Views.Length) ? Views[li] : null; if (lz == null) return null;
            L l = Lights[li]; double[] d = l.Dir; if (d == null) return null;
            int upAx = Math.Abs(d[1]) > 0.9 ? 0 : 1;      // a light facing straight up or down: lean on x instead
            x = (float)(l.X + l.Jx); y = (float)(l.Y + l.Jy); z = (float)(l.Z + l.Jz);
            lz.LookAt(x, y, z, (float)(x + d[0] * 100), (float)(y + d[1] * 100), (float)(z + d[2] * 100), upAx);
            return lz;
        }
        /// <summary>THE PLACED LIGHTS' VIEWS on the graphics card: each shadowing light all round from where it is this frame.</summary>
        public void CardViews(GpuRaster gpu, int face)
        {
            for (int li = 0; li < Lights.Count; li++)
            {
                float x, y, z; if (AimView(li, out x, out y, out z) == null) continue;
                gpu.SetLightCube(li, x, y, z, face);
            }
        }
    }
}
