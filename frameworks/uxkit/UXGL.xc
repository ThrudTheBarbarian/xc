// UXGL.xc — the GL calls a renderer makes, declared once for every backend.
//
// A renderer imports this instead of declaring its own gl* externs, and the same source builds
// everywhere.  On macOS, Linux, iOS, Android and the web these are the platform's own functions:
// the link names the GL library (-framework OpenGL, -lGL, the OpenGLES framework, libGLESv3; the
// web's are host imports).  On win64, opengl32.dll exports only GL 1.1 and the toolchain links none
// of it, so each one here is a small function that finds the real entry point through the driver
// (UXViewDriver.glProc: wglGetProcAddress, else opengl32's own export) the first time it is called,
// with a context current, and calls it; a call the context does not have does nothing (and answers
// 0) rather than jumping to address 0.  The types are the C API's: GLenum and GLuint u32, GLint and
// GLsizei i32, GLsizeiptr i64, GLboolean u8, GLfloat float, GLchar u8.
//
// The set is the GL 3.2 core a 2-D-and-tiles renderer uses -- buffers, vertex arrays, shaders,
// textures, framebuffers, uniforms -- plus their deletes and glViewport / glGetError.  A call not
// here can be reached through glProc, or added here.

#if ARCH_win64
#import "UXViewDriver.xc" // gDriver.glProc

typedef void _uxgl_glActiveTexture_t(u32 texture);
_uxgl_glActiveTexture_t* _uxgl_glActiveTexture;
void glActiveTexture(u32 texture)
    {
    if (_uxgl_glActiveTexture == (_uxgl_glActiveTexture_t*)0)
        {
        _uxgl_glActiveTexture = (_uxgl_glActiveTexture_t*)gDriver.glProc((u8*)"glActiveTexture");
        }
    if (_uxgl_glActiveTexture != (_uxgl_glActiveTexture_t*)0)
        {
        _uxgl_glActiveTexture(texture);
        }
    }
typedef void _uxgl_glAttachShader_t(u32 program, u32 shader);
_uxgl_glAttachShader_t* _uxgl_glAttachShader;
void glAttachShader(u32 program, u32 shader)
    {
    if (_uxgl_glAttachShader == (_uxgl_glAttachShader_t*)0)
        {
        _uxgl_glAttachShader = (_uxgl_glAttachShader_t*)gDriver.glProc((u8*)"glAttachShader");
        }
    if (_uxgl_glAttachShader != (_uxgl_glAttachShader_t*)0)
        {
        _uxgl_glAttachShader(program, shader);
        }
    }
typedef void _uxgl_glBindBuffer_t(u32 target, u32 buffer);
_uxgl_glBindBuffer_t* _uxgl_glBindBuffer;
void glBindBuffer(u32 target, u32 buffer)
    {
    if (_uxgl_glBindBuffer == (_uxgl_glBindBuffer_t*)0)
        {
        _uxgl_glBindBuffer = (_uxgl_glBindBuffer_t*)gDriver.glProc((u8*)"glBindBuffer");
        }
    if (_uxgl_glBindBuffer != (_uxgl_glBindBuffer_t*)0)
        {
        _uxgl_glBindBuffer(target, buffer);
        }
    }
typedef void _uxgl_glBindFramebuffer_t(u32 target, u32 framebuffer);
_uxgl_glBindFramebuffer_t* _uxgl_glBindFramebuffer;
void glBindFramebuffer(u32 target, u32 framebuffer)
    {
    if (_uxgl_glBindFramebuffer == (_uxgl_glBindFramebuffer_t*)0)
        {
        _uxgl_glBindFramebuffer = (_uxgl_glBindFramebuffer_t*)gDriver.glProc((u8*)"glBindFramebuffer");
        }
    if (_uxgl_glBindFramebuffer != (_uxgl_glBindFramebuffer_t*)0)
        {
        _uxgl_glBindFramebuffer(target, framebuffer);
        }
    }
typedef void _uxgl_glBindTexture_t(u32 target, u32 texture);
_uxgl_glBindTexture_t* _uxgl_glBindTexture;
void glBindTexture(u32 target, u32 texture)
    {
    if (_uxgl_glBindTexture == (_uxgl_glBindTexture_t*)0)
        {
        _uxgl_glBindTexture = (_uxgl_glBindTexture_t*)gDriver.glProc((u8*)"glBindTexture");
        }
    if (_uxgl_glBindTexture != (_uxgl_glBindTexture_t*)0)
        {
        _uxgl_glBindTexture(target, texture);
        }
    }
typedef void _uxgl_glBindVertexArray_t(u32 array);
_uxgl_glBindVertexArray_t* _uxgl_glBindVertexArray;
void glBindVertexArray(u32 array)
    {
    if (_uxgl_glBindVertexArray == (_uxgl_glBindVertexArray_t*)0)
        {
        _uxgl_glBindVertexArray = (_uxgl_glBindVertexArray_t*)gDriver.glProc((u8*)"glBindVertexArray");
        }
    if (_uxgl_glBindVertexArray != (_uxgl_glBindVertexArray_t*)0)
        {
        _uxgl_glBindVertexArray(array);
        }
    }
typedef void _uxgl_glBlendFunc_t(u32 sfactor, u32 dfactor);
_uxgl_glBlendFunc_t* _uxgl_glBlendFunc;
void glBlendFunc(u32 sfactor, u32 dfactor)
    {
    if (_uxgl_glBlendFunc == (_uxgl_glBlendFunc_t*)0)
        {
        _uxgl_glBlendFunc = (_uxgl_glBlendFunc_t*)gDriver.glProc((u8*)"glBlendFunc");
        }
    if (_uxgl_glBlendFunc != (_uxgl_glBlendFunc_t*)0)
        {
        _uxgl_glBlendFunc(sfactor, dfactor);
        }
    }
typedef void _uxgl_glBufferData_t(u32 target, i64 size, pointer data, u32 usage);
_uxgl_glBufferData_t* _uxgl_glBufferData;
void glBufferData(u32 target, i64 size, pointer data, u32 usage)
    {
    if (_uxgl_glBufferData == (_uxgl_glBufferData_t*)0)
        {
        _uxgl_glBufferData = (_uxgl_glBufferData_t*)gDriver.glProc((u8*)"glBufferData");
        }
    if (_uxgl_glBufferData != (_uxgl_glBufferData_t*)0)
        {
        _uxgl_glBufferData(target, size, data, usage);
        }
    }
typedef u32 _uxgl_glCheckFramebufferStatus_t(u32 target);
_uxgl_glCheckFramebufferStatus_t* _uxgl_glCheckFramebufferStatus;
u32 glCheckFramebufferStatus(u32 target)
    {
    if (_uxgl_glCheckFramebufferStatus == (_uxgl_glCheckFramebufferStatus_t*)0)
        {
        _uxgl_glCheckFramebufferStatus = (_uxgl_glCheckFramebufferStatus_t*)gDriver.glProc((u8*)"glCheckFramebufferStatus");
        }
    if (_uxgl_glCheckFramebufferStatus == (_uxgl_glCheckFramebufferStatus_t*)0)
        {
        return (u32)0; // no such entry point in this context
        }
    return _uxgl_glCheckFramebufferStatus(target);
    }
typedef void _uxgl_glClear_t(u32 mask);
_uxgl_glClear_t* _uxgl_glClear;
void glClear(u32 mask)
    {
    if (_uxgl_glClear == (_uxgl_glClear_t*)0)
        {
        _uxgl_glClear = (_uxgl_glClear_t*)gDriver.glProc((u8*)"glClear");
        }
    if (_uxgl_glClear != (_uxgl_glClear_t*)0)
        {
        _uxgl_glClear(mask);
        }
    }
typedef void _uxgl_glClearColor_t(float r, float g, float b, float a);
_uxgl_glClearColor_t* _uxgl_glClearColor;
void glClearColor(float r, float g, float b, float a)
    {
    if (_uxgl_glClearColor == (_uxgl_glClearColor_t*)0)
        {
        _uxgl_glClearColor = (_uxgl_glClearColor_t*)gDriver.glProc((u8*)"glClearColor");
        }
    if (_uxgl_glClearColor != (_uxgl_glClearColor_t*)0)
        {
        _uxgl_glClearColor(r, g, b, a);
        }
    }
typedef void _uxgl_glCompileShader_t(u32 shader);
_uxgl_glCompileShader_t* _uxgl_glCompileShader;
void glCompileShader(u32 shader)
    {
    if (_uxgl_glCompileShader == (_uxgl_glCompileShader_t*)0)
        {
        _uxgl_glCompileShader = (_uxgl_glCompileShader_t*)gDriver.glProc((u8*)"glCompileShader");
        }
    if (_uxgl_glCompileShader != (_uxgl_glCompileShader_t*)0)
        {
        _uxgl_glCompileShader(shader);
        }
    }
typedef u32 _uxgl_glCreateProgram_t(void);
_uxgl_glCreateProgram_t* _uxgl_glCreateProgram;
u32 glCreateProgram(void)
    {
    if (_uxgl_glCreateProgram == (_uxgl_glCreateProgram_t*)0)
        {
        _uxgl_glCreateProgram = (_uxgl_glCreateProgram_t*)gDriver.glProc((u8*)"glCreateProgram");
        }
    if (_uxgl_glCreateProgram == (_uxgl_glCreateProgram_t*)0)
        {
        return (u32)0; // no such entry point in this context
        }
    return _uxgl_glCreateProgram();
    }
typedef u32 _uxgl_glCreateShader_t(u32 type);
_uxgl_glCreateShader_t* _uxgl_glCreateShader;
u32 glCreateShader(u32 type)
    {
    if (_uxgl_glCreateShader == (_uxgl_glCreateShader_t*)0)
        {
        _uxgl_glCreateShader = (_uxgl_glCreateShader_t*)gDriver.glProc((u8*)"glCreateShader");
        }
    if (_uxgl_glCreateShader == (_uxgl_glCreateShader_t*)0)
        {
        return (u32)0; // no such entry point in this context
        }
    return _uxgl_glCreateShader(type);
    }
typedef void _uxgl_glDeleteBuffers_t(i32 n, u32* buffers);
_uxgl_glDeleteBuffers_t* _uxgl_glDeleteBuffers;
void glDeleteBuffers(i32 n, u32* buffers)
    {
    if (_uxgl_glDeleteBuffers == (_uxgl_glDeleteBuffers_t*)0)
        {
        _uxgl_glDeleteBuffers = (_uxgl_glDeleteBuffers_t*)gDriver.glProc((u8*)"glDeleteBuffers");
        }
    if (_uxgl_glDeleteBuffers != (_uxgl_glDeleteBuffers_t*)0)
        {
        _uxgl_glDeleteBuffers(n, buffers);
        }
    }
typedef void _uxgl_glDeleteFramebuffers_t(i32 n, u32* framebuffers);
_uxgl_glDeleteFramebuffers_t* _uxgl_glDeleteFramebuffers;
void glDeleteFramebuffers(i32 n, u32* framebuffers)
    {
    if (_uxgl_glDeleteFramebuffers == (_uxgl_glDeleteFramebuffers_t*)0)
        {
        _uxgl_glDeleteFramebuffers = (_uxgl_glDeleteFramebuffers_t*)gDriver.glProc((u8*)"glDeleteFramebuffers");
        }
    if (_uxgl_glDeleteFramebuffers != (_uxgl_glDeleteFramebuffers_t*)0)
        {
        _uxgl_glDeleteFramebuffers(n, framebuffers);
        }
    }
typedef void _uxgl_glDeleteProgram_t(u32 program);
_uxgl_glDeleteProgram_t* _uxgl_glDeleteProgram;
void glDeleteProgram(u32 program)
    {
    if (_uxgl_glDeleteProgram == (_uxgl_glDeleteProgram_t*)0)
        {
        _uxgl_glDeleteProgram = (_uxgl_glDeleteProgram_t*)gDriver.glProc((u8*)"glDeleteProgram");
        }
    if (_uxgl_glDeleteProgram != (_uxgl_glDeleteProgram_t*)0)
        {
        _uxgl_glDeleteProgram(program);
        }
    }
typedef void _uxgl_glDeleteShader_t(u32 shader);
_uxgl_glDeleteShader_t* _uxgl_glDeleteShader;
void glDeleteShader(u32 shader)
    {
    if (_uxgl_glDeleteShader == (_uxgl_glDeleteShader_t*)0)
        {
        _uxgl_glDeleteShader = (_uxgl_glDeleteShader_t*)gDriver.glProc((u8*)"glDeleteShader");
        }
    if (_uxgl_glDeleteShader != (_uxgl_glDeleteShader_t*)0)
        {
        _uxgl_glDeleteShader(shader);
        }
    }
typedef void _uxgl_glDeleteTextures_t(i32 n, u32* textures);
_uxgl_glDeleteTextures_t* _uxgl_glDeleteTextures;
void glDeleteTextures(i32 n, u32* textures)
    {
    if (_uxgl_glDeleteTextures == (_uxgl_glDeleteTextures_t*)0)
        {
        _uxgl_glDeleteTextures = (_uxgl_glDeleteTextures_t*)gDriver.glProc((u8*)"glDeleteTextures");
        }
    if (_uxgl_glDeleteTextures != (_uxgl_glDeleteTextures_t*)0)
        {
        _uxgl_glDeleteTextures(n, textures);
        }
    }
typedef void _uxgl_glDeleteVertexArrays_t(i32 n, u32* arrays);
_uxgl_glDeleteVertexArrays_t* _uxgl_glDeleteVertexArrays;
void glDeleteVertexArrays(i32 n, u32* arrays)
    {
    if (_uxgl_glDeleteVertexArrays == (_uxgl_glDeleteVertexArrays_t*)0)
        {
        _uxgl_glDeleteVertexArrays = (_uxgl_glDeleteVertexArrays_t*)gDriver.glProc((u8*)"glDeleteVertexArrays");
        }
    if (_uxgl_glDeleteVertexArrays != (_uxgl_glDeleteVertexArrays_t*)0)
        {
        _uxgl_glDeleteVertexArrays(n, arrays);
        }
    }
typedef void _uxgl_glDisable_t(u32 cap);
_uxgl_glDisable_t* _uxgl_glDisable;
void glDisable(u32 cap)
    {
    if (_uxgl_glDisable == (_uxgl_glDisable_t*)0)
        {
        _uxgl_glDisable = (_uxgl_glDisable_t*)gDriver.glProc((u8*)"glDisable");
        }
    if (_uxgl_glDisable != (_uxgl_glDisable_t*)0)
        {
        _uxgl_glDisable(cap);
        }
    }
typedef void _uxgl_glDisableVertexAttribArray_t(u32 index);
_uxgl_glDisableVertexAttribArray_t* _uxgl_glDisableVertexAttribArray;
void glDisableVertexAttribArray(u32 index)
    {
    if (_uxgl_glDisableVertexAttribArray == (_uxgl_glDisableVertexAttribArray_t*)0)
        {
        _uxgl_glDisableVertexAttribArray = (_uxgl_glDisableVertexAttribArray_t*)gDriver.glProc((u8*)"glDisableVertexAttribArray");
        }
    if (_uxgl_glDisableVertexAttribArray != (_uxgl_glDisableVertexAttribArray_t*)0)
        {
        _uxgl_glDisableVertexAttribArray(index);
        }
    }
typedef void _uxgl_glDrawArrays_t(u32 mode, i32 first, i32 count);
_uxgl_glDrawArrays_t* _uxgl_glDrawArrays;
void glDrawArrays(u32 mode, i32 first, i32 count)
    {
    if (_uxgl_glDrawArrays == (_uxgl_glDrawArrays_t*)0)
        {
        _uxgl_glDrawArrays = (_uxgl_glDrawArrays_t*)gDriver.glProc((u8*)"glDrawArrays");
        }
    if (_uxgl_glDrawArrays != (_uxgl_glDrawArrays_t*)0)
        {
        _uxgl_glDrawArrays(mode, first, count);
        }
    }
typedef void _uxgl_glEnable_t(u32 cap);
_uxgl_glEnable_t* _uxgl_glEnable;
void glEnable(u32 cap)
    {
    if (_uxgl_glEnable == (_uxgl_glEnable_t*)0)
        {
        _uxgl_glEnable = (_uxgl_glEnable_t*)gDriver.glProc((u8*)"glEnable");
        }
    if (_uxgl_glEnable != (_uxgl_glEnable_t*)0)
        {
        _uxgl_glEnable(cap);
        }
    }
typedef void _uxgl_glEnableVertexAttribArray_t(u32 index);
_uxgl_glEnableVertexAttribArray_t* _uxgl_glEnableVertexAttribArray;
void glEnableVertexAttribArray(u32 index)
    {
    if (_uxgl_glEnableVertexAttribArray == (_uxgl_glEnableVertexAttribArray_t*)0)
        {
        _uxgl_glEnableVertexAttribArray = (_uxgl_glEnableVertexAttribArray_t*)gDriver.glProc((u8*)"glEnableVertexAttribArray");
        }
    if (_uxgl_glEnableVertexAttribArray != (_uxgl_glEnableVertexAttribArray_t*)0)
        {
        _uxgl_glEnableVertexAttribArray(index);
        }
    }
typedef void _uxgl_glFinish_t(void);
_uxgl_glFinish_t* _uxgl_glFinish;
void glFinish(void)
    {
    if (_uxgl_glFinish == (_uxgl_glFinish_t*)0)
        {
        _uxgl_glFinish = (_uxgl_glFinish_t*)gDriver.glProc((u8*)"glFinish");
        }
    if (_uxgl_glFinish != (_uxgl_glFinish_t*)0)
        {
        _uxgl_glFinish();
        }
    }
typedef void _uxgl_glFramebufferTexture2D_t(u32 target, u32 attachment, u32 textarget, u32 texture, i32 level);
_uxgl_glFramebufferTexture2D_t* _uxgl_glFramebufferTexture2D;
void glFramebufferTexture2D(u32 target, u32 attachment, u32 textarget, u32 texture, i32 level)
    {
    if (_uxgl_glFramebufferTexture2D == (_uxgl_glFramebufferTexture2D_t*)0)
        {
        _uxgl_glFramebufferTexture2D = (_uxgl_glFramebufferTexture2D_t*)gDriver.glProc((u8*)"glFramebufferTexture2D");
        }
    if (_uxgl_glFramebufferTexture2D != (_uxgl_glFramebufferTexture2D_t*)0)
        {
        _uxgl_glFramebufferTexture2D(target, attachment, textarget, texture, level);
        }
    }
typedef void _uxgl_glGenBuffers_t(i32 n, u32* buffers);
_uxgl_glGenBuffers_t* _uxgl_glGenBuffers;
void glGenBuffers(i32 n, u32* buffers)
    {
    if (_uxgl_glGenBuffers == (_uxgl_glGenBuffers_t*)0)
        {
        _uxgl_glGenBuffers = (_uxgl_glGenBuffers_t*)gDriver.glProc((u8*)"glGenBuffers");
        }
    if (_uxgl_glGenBuffers != (_uxgl_glGenBuffers_t*)0)
        {
        _uxgl_glGenBuffers(n, buffers);
        }
    }
typedef void _uxgl_glGenFramebuffers_t(i32 n, u32* framebuffers);
_uxgl_glGenFramebuffers_t* _uxgl_glGenFramebuffers;
void glGenFramebuffers(i32 n, u32* framebuffers)
    {
    if (_uxgl_glGenFramebuffers == (_uxgl_glGenFramebuffers_t*)0)
        {
        _uxgl_glGenFramebuffers = (_uxgl_glGenFramebuffers_t*)gDriver.glProc((u8*)"glGenFramebuffers");
        }
    if (_uxgl_glGenFramebuffers != (_uxgl_glGenFramebuffers_t*)0)
        {
        _uxgl_glGenFramebuffers(n, framebuffers);
        }
    }
typedef void _uxgl_glGenTextures_t(i32 n, u32* textures);
_uxgl_glGenTextures_t* _uxgl_glGenTextures;
void glGenTextures(i32 n, u32* textures)
    {
    if (_uxgl_glGenTextures == (_uxgl_glGenTextures_t*)0)
        {
        _uxgl_glGenTextures = (_uxgl_glGenTextures_t*)gDriver.glProc((u8*)"glGenTextures");
        }
    if (_uxgl_glGenTextures != (_uxgl_glGenTextures_t*)0)
        {
        _uxgl_glGenTextures(n, textures);
        }
    }
typedef void _uxgl_glGenVertexArrays_t(i32 n, u32* arrays);
_uxgl_glGenVertexArrays_t* _uxgl_glGenVertexArrays;
void glGenVertexArrays(i32 n, u32* arrays)
    {
    if (_uxgl_glGenVertexArrays == (_uxgl_glGenVertexArrays_t*)0)
        {
        _uxgl_glGenVertexArrays = (_uxgl_glGenVertexArrays_t*)gDriver.glProc((u8*)"glGenVertexArrays");
        }
    if (_uxgl_glGenVertexArrays != (_uxgl_glGenVertexArrays_t*)0)
        {
        _uxgl_glGenVertexArrays(n, arrays);
        }
    }
typedef void _uxgl_glGenerateMipmap_t(u32 target);
_uxgl_glGenerateMipmap_t* _uxgl_glGenerateMipmap;
void glGenerateMipmap(u32 target)
    {
    if (_uxgl_glGenerateMipmap == (_uxgl_glGenerateMipmap_t*)0)
        {
        _uxgl_glGenerateMipmap = (_uxgl_glGenerateMipmap_t*)gDriver.glProc((u8*)"glGenerateMipmap");
        }
    if (_uxgl_glGenerateMipmap != (_uxgl_glGenerateMipmap_t*)0)
        {
        _uxgl_glGenerateMipmap(target);
        }
    }
typedef i32 _uxgl_glGetAttribLocation_t(u32 program, u8* name);
_uxgl_glGetAttribLocation_t* _uxgl_glGetAttribLocation;
i32 glGetAttribLocation(u32 program, u8* name)
    {
    if (_uxgl_glGetAttribLocation == (_uxgl_glGetAttribLocation_t*)0)
        {
        _uxgl_glGetAttribLocation = (_uxgl_glGetAttribLocation_t*)gDriver.glProc((u8*)"glGetAttribLocation");
        }
    if (_uxgl_glGetAttribLocation == (_uxgl_glGetAttribLocation_t*)0)
        {
        return (i32)0; // no such entry point in this context
        }
    return _uxgl_glGetAttribLocation(program, name);
    }
typedef u32 _uxgl_glGetError_t(void);
_uxgl_glGetError_t* _uxgl_glGetError;
u32 glGetError(void)
    {
    if (_uxgl_glGetError == (_uxgl_glGetError_t*)0)
        {
        _uxgl_glGetError = (_uxgl_glGetError_t*)gDriver.glProc((u8*)"glGetError");
        }
    if (_uxgl_glGetError == (_uxgl_glGetError_t*)0)
        {
        return (u32)0; // no such entry point in this context
        }
    return _uxgl_glGetError();
    }
typedef void _uxgl_glGetIntegerv_t(u32 pname, i32* data);
_uxgl_glGetIntegerv_t* _uxgl_glGetIntegerv;
void glGetIntegerv(u32 pname, i32* data)
    {
    if (_uxgl_glGetIntegerv == (_uxgl_glGetIntegerv_t*)0)
        {
        _uxgl_glGetIntegerv = (_uxgl_glGetIntegerv_t*)gDriver.glProc((u8*)"glGetIntegerv");
        }
    if (_uxgl_glGetIntegerv != (_uxgl_glGetIntegerv_t*)0)
        {
        _uxgl_glGetIntegerv(pname, data);
        }
    }
typedef void _uxgl_glGetProgramInfoLog_t(u32 program, i32 bufSize, i32* length, u8* infoLog);
_uxgl_glGetProgramInfoLog_t* _uxgl_glGetProgramInfoLog;
void glGetProgramInfoLog(u32 program, i32 bufSize, i32* length, u8* infoLog)
    {
    if (_uxgl_glGetProgramInfoLog == (_uxgl_glGetProgramInfoLog_t*)0)
        {
        _uxgl_glGetProgramInfoLog = (_uxgl_glGetProgramInfoLog_t*)gDriver.glProc((u8*)"glGetProgramInfoLog");
        }
    if (_uxgl_glGetProgramInfoLog != (_uxgl_glGetProgramInfoLog_t*)0)
        {
        _uxgl_glGetProgramInfoLog(program, bufSize, length, infoLog);
        }
    }
typedef void _uxgl_glGetProgramiv_t(u32 program, u32 pname, i32* params);
_uxgl_glGetProgramiv_t* _uxgl_glGetProgramiv;
void glGetProgramiv(u32 program, u32 pname, i32* params)
    {
    if (_uxgl_glGetProgramiv == (_uxgl_glGetProgramiv_t*)0)
        {
        _uxgl_glGetProgramiv = (_uxgl_glGetProgramiv_t*)gDriver.glProc((u8*)"glGetProgramiv");
        }
    if (_uxgl_glGetProgramiv != (_uxgl_glGetProgramiv_t*)0)
        {
        _uxgl_glGetProgramiv(program, pname, params);
        }
    }
typedef void _uxgl_glGetShaderInfoLog_t(u32 shader, i32 bufSize, i32* length, u8* infoLog);
_uxgl_glGetShaderInfoLog_t* _uxgl_glGetShaderInfoLog;
void glGetShaderInfoLog(u32 shader, i32 bufSize, i32* length, u8* infoLog)
    {
    if (_uxgl_glGetShaderInfoLog == (_uxgl_glGetShaderInfoLog_t*)0)
        {
        _uxgl_glGetShaderInfoLog = (_uxgl_glGetShaderInfoLog_t*)gDriver.glProc((u8*)"glGetShaderInfoLog");
        }
    if (_uxgl_glGetShaderInfoLog != (_uxgl_glGetShaderInfoLog_t*)0)
        {
        _uxgl_glGetShaderInfoLog(shader, bufSize, length, infoLog);
        }
    }
typedef void _uxgl_glGetShaderiv_t(u32 shader, u32 pname, i32* params);
_uxgl_glGetShaderiv_t* _uxgl_glGetShaderiv;
void glGetShaderiv(u32 shader, u32 pname, i32* params)
    {
    if (_uxgl_glGetShaderiv == (_uxgl_glGetShaderiv_t*)0)
        {
        _uxgl_glGetShaderiv = (_uxgl_glGetShaderiv_t*)gDriver.glProc((u8*)"glGetShaderiv");
        }
    if (_uxgl_glGetShaderiv != (_uxgl_glGetShaderiv_t*)0)
        {
        _uxgl_glGetShaderiv(shader, pname, params);
        }
    }
typedef i32 _uxgl_glGetUniformLocation_t(u32 program, u8* name);
_uxgl_glGetUniformLocation_t* _uxgl_glGetUniformLocation;
i32 glGetUniformLocation(u32 program, u8* name)
    {
    if (_uxgl_glGetUniformLocation == (_uxgl_glGetUniformLocation_t*)0)
        {
        _uxgl_glGetUniformLocation = (_uxgl_glGetUniformLocation_t*)gDriver.glProc((u8*)"glGetUniformLocation");
        }
    if (_uxgl_glGetUniformLocation == (_uxgl_glGetUniformLocation_t*)0)
        {
        return (i32)0; // no such entry point in this context
        }
    return _uxgl_glGetUniformLocation(program, name);
    }
typedef void _uxgl_glLinkProgram_t(u32 program);
_uxgl_glLinkProgram_t* _uxgl_glLinkProgram;
void glLinkProgram(u32 program)
    {
    if (_uxgl_glLinkProgram == (_uxgl_glLinkProgram_t*)0)
        {
        _uxgl_glLinkProgram = (_uxgl_glLinkProgram_t*)gDriver.glProc((u8*)"glLinkProgram");
        }
    if (_uxgl_glLinkProgram != (_uxgl_glLinkProgram_t*)0)
        {
        _uxgl_glLinkProgram(program);
        }
    }
typedef void _uxgl_glPixelStorei_t(u32 pname, i32 param);
_uxgl_glPixelStorei_t* _uxgl_glPixelStorei;
void glPixelStorei(u32 pname, i32 param)
    {
    if (_uxgl_glPixelStorei == (_uxgl_glPixelStorei_t*)0)
        {
        _uxgl_glPixelStorei = (_uxgl_glPixelStorei_t*)gDriver.glProc((u8*)"glPixelStorei");
        }
    if (_uxgl_glPixelStorei != (_uxgl_glPixelStorei_t*)0)
        {
        _uxgl_glPixelStorei(pname, param);
        }
    }
typedef void _uxgl_glReadPixels_t(i32 x, i32 y, i32 w, i32 h, u32 format, u32 type, pointer data);
_uxgl_glReadPixels_t* _uxgl_glReadPixels;
void glReadPixels(i32 x, i32 y, i32 w, i32 h, u32 format, u32 type, pointer data)
    {
    if (_uxgl_glReadPixels == (_uxgl_glReadPixels_t*)0)
        {
        _uxgl_glReadPixels = (_uxgl_glReadPixels_t*)gDriver.glProc((u8*)"glReadPixels");
        }
    if (_uxgl_glReadPixels != (_uxgl_glReadPixels_t*)0)
        {
        _uxgl_glReadPixels(x, y, w, h, format, type, data);
        }
    }
typedef void _uxgl_glShaderSource_t(u32 shader, i32 count, u8** strings, i32* length);
_uxgl_glShaderSource_t* _uxgl_glShaderSource;
void glShaderSource(u32 shader, i32 count, u8** strings, i32* length)
    {
    if (_uxgl_glShaderSource == (_uxgl_glShaderSource_t*)0)
        {
        _uxgl_glShaderSource = (_uxgl_glShaderSource_t*)gDriver.glProc((u8*)"glShaderSource");
        }
    if (_uxgl_glShaderSource != (_uxgl_glShaderSource_t*)0)
        {
        _uxgl_glShaderSource(shader, count, strings, length);
        }
    }
typedef void _uxgl_glTexImage2D_t(u32 target, i32 level, i32 internalformat, i32 w, i32 h, i32 border, u32 format, u32 type, pointer data);
_uxgl_glTexImage2D_t* _uxgl_glTexImage2D;
void glTexImage2D(u32 target, i32 level, i32 internalformat, i32 w, i32 h, i32 border, u32 format, u32 type, pointer data)
    {
    if (_uxgl_glTexImage2D == (_uxgl_glTexImage2D_t*)0)
        {
        _uxgl_glTexImage2D = (_uxgl_glTexImage2D_t*)gDriver.glProc((u8*)"glTexImage2D");
        }
    if (_uxgl_glTexImage2D != (_uxgl_glTexImage2D_t*)0)
        {
        _uxgl_glTexImage2D(target, level, internalformat, w, h, border, format, type, data);
        }
    }
typedef void _uxgl_glTexParameteri_t(u32 target, u32 pname, i32 param);
_uxgl_glTexParameteri_t* _uxgl_glTexParameteri;
void glTexParameteri(u32 target, u32 pname, i32 param)
    {
    if (_uxgl_glTexParameteri == (_uxgl_glTexParameteri_t*)0)
        {
        _uxgl_glTexParameteri = (_uxgl_glTexParameteri_t*)gDriver.glProc((u8*)"glTexParameteri");
        }
    if (_uxgl_glTexParameteri != (_uxgl_glTexParameteri_t*)0)
        {
        _uxgl_glTexParameteri(target, pname, param);
        }
    }
typedef void _uxgl_glUniform1f_t(i32 location, float v0);
_uxgl_glUniform1f_t* _uxgl_glUniform1f;
void glUniform1f(i32 location, float v0)
    {
    if (_uxgl_glUniform1f == (_uxgl_glUniform1f_t*)0)
        {
        _uxgl_glUniform1f = (_uxgl_glUniform1f_t*)gDriver.glProc((u8*)"glUniform1f");
        }
    if (_uxgl_glUniform1f != (_uxgl_glUniform1f_t*)0)
        {
        _uxgl_glUniform1f(location, v0);
        }
    }
typedef void _uxgl_glUniform1i_t(i32 location, i32 v0);
_uxgl_glUniform1i_t* _uxgl_glUniform1i;
void glUniform1i(i32 location, i32 v0)
    {
    if (_uxgl_glUniform1i == (_uxgl_glUniform1i_t*)0)
        {
        _uxgl_glUniform1i = (_uxgl_glUniform1i_t*)gDriver.glProc((u8*)"glUniform1i");
        }
    if (_uxgl_glUniform1i != (_uxgl_glUniform1i_t*)0)
        {
        _uxgl_glUniform1i(location, v0);
        }
    }
typedef void _uxgl_glUniform2f_t(i32 location, float v0, float v1);
_uxgl_glUniform2f_t* _uxgl_glUniform2f;
void glUniform2f(i32 location, float v0, float v1)
    {
    if (_uxgl_glUniform2f == (_uxgl_glUniform2f_t*)0)
        {
        _uxgl_glUniform2f = (_uxgl_glUniform2f_t*)gDriver.glProc((u8*)"glUniform2f");
        }
    if (_uxgl_glUniform2f != (_uxgl_glUniform2f_t*)0)
        {
        _uxgl_glUniform2f(location, v0, v1);
        }
    }
typedef void _uxgl_glUniform4fv_t(i32 location, i32 count, float* value);
_uxgl_glUniform4fv_t* _uxgl_glUniform4fv;
void glUniform4fv(i32 location, i32 count, float* value)
    {
    if (_uxgl_glUniform4fv == (_uxgl_glUniform4fv_t*)0)
        {
        _uxgl_glUniform4fv = (_uxgl_glUniform4fv_t*)gDriver.glProc((u8*)"glUniform4fv");
        }
    if (_uxgl_glUniform4fv != (_uxgl_glUniform4fv_t*)0)
        {
        _uxgl_glUniform4fv(location, count, value);
        }
    }
typedef void _uxgl_glUseProgram_t(u32 program);
_uxgl_glUseProgram_t* _uxgl_glUseProgram;
void glUseProgram(u32 program)
    {
    if (_uxgl_glUseProgram == (_uxgl_glUseProgram_t*)0)
        {
        _uxgl_glUseProgram = (_uxgl_glUseProgram_t*)gDriver.glProc((u8*)"glUseProgram");
        }
    if (_uxgl_glUseProgram != (_uxgl_glUseProgram_t*)0)
        {
        _uxgl_glUseProgram(program);
        }
    }
typedef void _uxgl_glVertexAttribPointer_t(u32 index, i32 size, u32 type, u8 normalized, i32 stride, pointer offset);
_uxgl_glVertexAttribPointer_t* _uxgl_glVertexAttribPointer;
void glVertexAttribPointer(u32 index, i32 size, u32 type, u8 normalized, i32 stride, pointer offset)
    {
    if (_uxgl_glVertexAttribPointer == (_uxgl_glVertexAttribPointer_t*)0)
        {
        _uxgl_glVertexAttribPointer = (_uxgl_glVertexAttribPointer_t*)gDriver.glProc((u8*)"glVertexAttribPointer");
        }
    if (_uxgl_glVertexAttribPointer != (_uxgl_glVertexAttribPointer_t*)0)
        {
        _uxgl_glVertexAttribPointer(index, size, type, normalized, stride, offset);
        }
    }
typedef void _uxgl_glViewport_t(i32 x, i32 y, i32 w, i32 h);
_uxgl_glViewport_t* _uxgl_glViewport;
void glViewport(i32 x, i32 y, i32 w, i32 h)
    {
    if (_uxgl_glViewport == (_uxgl_glViewport_t*)0)
        {
        _uxgl_glViewport = (_uxgl_glViewport_t*)gDriver.glProc((u8*)"glViewport");
        }
    if (_uxgl_glViewport != (_uxgl_glViewport_t*)0)
        {
        _uxgl_glViewport(x, y, w, h);
        }
    }
#else
// The declarations live in one file, which install.sh ships to clients as 3p/uxkit/xc/UXGL.xc: an
// interface leaves bodyless prototypes out (bug 638), so a #use <UXKit> client imports that one.
#import "UXGLProtos.xc"
#endif
