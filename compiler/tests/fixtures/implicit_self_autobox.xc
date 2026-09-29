// A string literal passed to a String* parameter is boxed on every call
// form, including an implicit-self call (`join(x, "cd")` inside the class).
#use Stdio

class P
    {
    i32 pad;

    String* join(String* a, String* b)
        {
        String* s = String.withString(a);
        s.append(b);
        return s;
        }

    static String* sjoin(String* a, String* b)
        {
        String* s = String.withString(a);
        s.append(b);
        return s;
        }

    void run(void)
        {
        String* x = String.withCString("ab");
        Stdio.printf("%s\n", join(x, "cd").cString());
        Stdio.printf("%s\n", self.join(x, "ef").cString());
        }
    }

i32 main(void)
    {
    P* p = new P();
    p.run();
    String* x = String.withCString("gh");
    Stdio.printf("%s\n", p.join(x, "ij").cString());
    Stdio.printf("%s\n", P.sjoin(x, "kl").cString());
    return 0;
    }
