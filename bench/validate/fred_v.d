//
//when doing C-T regexes, use -J.; pattern for C-T regex is located in file ct_pattern !
module fred_v;

import std.file;
import std.stdio;
import std.datetime;
import std.conv;
import fred;
version(backtracking)
	alias bmatch matchFn;
else version(thompson)	
	alias match matchFn;
else version(ct_regex)
	alias match matchFn;
else	
	static assert(0, "Use -version=backtracking or -version=thompson or -version=ct_regex");

int main(string[] argv)
{
    if(argv.length < 4){
        writefln("Usage %s <re> file <iterations>",argv[0]);
        return 1;
    }
    version(ct_regex)
        auto engine = ctRegex!(import("ct_pattern"));
    else
        auto engine = regex(argv[1]);
    auto data = cast(char[])std.file.read(argv[2]);
    auto lines = split(data, regex("\r\n|\r|\n"));
    size_t count=0;
    size_t iterations = to!size_t(argv[3]);
    StopWatch sw;
    sw.start();
    for(size_t i=0; i<iterations; i++)
	{
		foreach(line; lines)
		{
			auto m = matchFn(line, engine);
			if(m)
				count++;
		}
	}
    sw.stop();
    auto dt = sw.peek().msecs;
    writefln("Total matches %s.\nTime elapsed %s sec",count,dt/1000.0);
    return 0;
}

