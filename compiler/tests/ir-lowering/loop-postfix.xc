// loop-postfix — counted for-loop using POSTFIX increment (i++).
//
// Regression: `i++` as the loop increment must mark `i` as an
// assigned local so a phi is placed at the loop header. Without it
// the header keeps reading i's pre-loop value, the back-edge never
// observes the bump, and the loop spins forever. Sum 0+1+…+9 = 45.
u16 sum_postfix(void)
    {
    u16 total = (u16)0;
    for (u16 i = (u16)0; i < (u16)10; i++)
        {
        total = total + i;
        }
    return total;
    }
