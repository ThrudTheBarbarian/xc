// cast_generic.xc — a cast to a typed collection pointer (astronomancy,
// 2026-10-25): `(Array<AMSkyPoint>*)0` failed at the `*)` with "Unexpected
// token ')'", though `Array<AMSkyPoint>* marks;` declares. In a conditional,
// a comparison, nested (`>>` closing two lists), with two arguments, and a
// parenthesised `a < b` beside them that stays a comparison.

#import "Stdio.xc"
#import "Foundation.xc"

class Mark : Object
	{
	i32 v;
	}

Array<Mark>* make(void)
	{
	Array<Mark>* a = new Array();
	Mark* m = new Mark();
	m.v = 7;
	a.add(m);
	return a;
	}

void main(void)
	{
	bool ok = true;
	Array<Mark>* marks = ok ? make() : (Array<Mark>*)0;
	if (marks != (Array<Mark>*)0)
		Stdio.printf("marks %u first %d\n", marks.count(), ((Mark*)marks.get(0)).v);
	Array<Mark>* none = !ok ? make() : (Array<Mark>*)0;
	Stdio.printf("none %d\n", none == (Array<Mark>*)0 ? 1 : 0);
	Map<String, Array<Mark>>* m = (Map<String, Array<Mark>>*)0;
	Array<Array<Mark>>* aa = (Array<Array<Mark>>*)0;
	i32 a = 3;
	i32 b = 5;
	bool lt = (a < b);
	Stdio.printf("nil %d %d lt %d\n", m == (Map<String, Array<Mark>>*)0 ? 1 : 0, aa == (Array<Array<Mark>>*)0 ? 1 : 0, lt ? 1 : 0);
	}
