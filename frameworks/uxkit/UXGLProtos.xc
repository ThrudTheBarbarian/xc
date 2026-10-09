// UXGLProtos.xc — the GL calls UXKit's renderers make, as DECLARATIONS ONLY.
//
// UXGL.xc defines these for a program that imports the framework's sources; a library interface
// leaves bodyless prototypes out (bug 638), so a client built with #use <UXKit> gets this file
// instead: install.sh ships it as 3p/uxkit/xc/UXGL.xc.  A client imports it and links GL itself:
//
//     #import "UXGL.xc"
//
// The link names the platform's GL (-framework OpenGL, -lGL, the OpenGLES framework, libGLESv3; the
// web's are host imports).  On win64 the library carries the wrappers (opengl32.dll exports only GL
// 1.1), so a win64 client needs no extra link.  The types are the C API's: GLenum/GLuint u32,
// GLint/GLsizei i32, GLsizeiptr i64, GLboolean u8, GLfloat float, GLchar u8.
void glActiveTexture(u32 texture);
void glAttachShader(u32 program, u32 shader);
void glBindBuffer(u32 target, u32 buffer);
void glBindFramebuffer(u32 target, u32 framebuffer);
void glBindTexture(u32 target, u32 texture);
void glBindVertexArray(u32 array);
void glBlendFunc(u32 sfactor, u32 dfactor);
void glBufferData(u32 target, i64 size, pointer data, u32 usage);
u32 glCheckFramebufferStatus(u32 target);
void glClear(u32 mask);
void glClearColor(float r, float g, float b, float a);
void glCompileShader(u32 shader);
u32 glCreateProgram(void);
u32 glCreateShader(u32 type);
void glDeleteBuffers(i32 n, u32* buffers);
void glDeleteFramebuffers(i32 n, u32* framebuffers);
void glDeleteProgram(u32 program);
void glDeleteShader(u32 shader);
void glDeleteTextures(i32 n, u32* textures);
void glDeleteVertexArrays(i32 n, u32* arrays);
void glDisable(u32 cap);
void glDisableVertexAttribArray(u32 index);
void glDrawArrays(u32 mode, i32 first, i32 count);
void glEnable(u32 cap);
void glEnableVertexAttribArray(u32 index);
void glFinish(void);
void glFramebufferTexture2D(u32 target, u32 attachment, u32 textarget, u32 texture, i32 level);
void glGenBuffers(i32 n, u32* buffers);
void glGenFramebuffers(i32 n, u32* framebuffers);
void glGenTextures(i32 n, u32* textures);
void glGenVertexArrays(i32 n, u32* arrays);
void glGenerateMipmap(u32 target);
i32 glGetAttribLocation(u32 program, u8* name);
u32 glGetError(void);
void glGetIntegerv(u32 pname, i32* data);
void glGetProgramInfoLog(u32 program, i32 bufSize, i32* length, u8* infoLog);
void glGetProgramiv(u32 program, u32 pname, i32* params);
void glGetShaderInfoLog(u32 shader, i32 bufSize, i32* length, u8* infoLog);
void glGetShaderiv(u32 shader, u32 pname, i32* params);
i32 glGetUniformLocation(u32 program, u8* name);
void glLinkProgram(u32 program);
void glPixelStorei(u32 pname, i32 param);
void glReadPixels(i32 x, i32 y, i32 w, i32 h, u32 format, u32 type, pointer data);
void glShaderSource(u32 shader, i32 count, u8** strings, i32* length);
void glTexImage2D(u32 target, i32 level, i32 internalformat, i32 w, i32 h, i32 border, u32 format, u32 type, pointer data);
void glTexParameteri(u32 target, u32 pname, i32 param);
void glUniform1f(i32 location, float v0);
void glUniform1i(i32 location, i32 v0);
void glUniform2f(i32 location, float v0, float v1);
void glUniform4fv(i32 location, i32 count, float* value);
void glUseProgram(u32 program);
void glVertexAttribPointer(u32 index, i32 size, u32 type, u8 normalized, i32 stride, pointer offset);
void glViewport(i32 x, i32 y, i32 w, i32 h);
