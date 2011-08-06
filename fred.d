//Written in the D programming language
/**
 * Fast Regular expressions for D
 *
 * License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
 *
 * Authors: Dmitry Olshansky
 *
 */
//TODO: kill GC allocations when possible (everywhere)
module fred;


import fred_uni;//unicode property tables
import std.stdio, core.stdc.stdlib, std.array, std.algorithm, std.range,
       std.conv, std.exception, std.traits, std.typetuple,
       std.uni, std.utf, std.format, std.typecons, std.bitmanip, std.functional, std.exception, std.regionallocator;
import core.bitop;
import ascii = std.ascii;

//uncomment to get a barrage of debug info
//debug = fred_parser;
//debug = fred_matching;
//debug = fred_charset;

/// [TODO: format for doc]
///  IR bit pattern: 0b1_xxxxx_yy
///  where yy indicates class of instruction, xxxxx for actual operation code
///      00: atom, a normal instruction
///      01: open, opening of a group, has length of contained IR in the low bits
///      10: close, closing of a group, has length of contained IR in the low bits
///      11 unused
///
//  Loops with Q (non-greedy, with ? mark) must have the same size / other properties as non Q version
/// open questions:
/// * encode non eagerness (*q) and groups with content (B) differently?
/// * merge group, option, infinite/repeat start (to never copy during parsing of (a|b){1,2}) ?
/// * reorganize groups to make n args easier to find, or simplify the check for groups of similar ops
///   (like lookaround), or make it easier to identify hotspots.
/// * there is still an unused bit that might be used for something
enum IR:uint {

    Char              = 0b1_00000_00, /// a character
    Any               = 0b1_00001_00, /// any character
    Charset           = 0b1_00010_00, /// a most generic charset [...]
    Trie              = 0b1_00011_00, /// charset implemented as Trie
    //place for two more atoms 
    Bol               = 0b1_00111_00, /// beginning of a string ^
    Eol               = 0b1_01000_00, /// end of a string $
    Wordboundary      = 0b1_01001_00, /// boundary of a word
    Notwordboundary   = 0b1_01010_00, /// not a word boundary
    Backref           = 0b1_01011_00, /// backreference to a group (that has to be pinned, i.e. locally unique) (group index)
    GroupStart        = 0b1_01100_00, /// start of a group (x) (groupIndex+groupPinning(1bit))
    GroupEnd          = 0b1_01101_00, /// end of a group (x) (groupIndex+groupPinning(1bit))
    Option            = 0b1_01110_00, /// start of an option within an alternation x | y (length)
    GotoEndOr         = 0b1_01111_00, /// end of an option (length of the rest)
    //... any additional atoms here    
    OrChar            = 0b1_11110_00,
    Nop               = 0b1_11111_00, /// no operation (padding)
    /// match with any of a consecutive OrChar's in this sequence (used for case insensitive match)
    /// OrChar holds in upper two bits of data total number of OrChars in this _sequence_
    /// the drawback of this representation is that it is difficult to detect a jump in the middle of it
    

    OrStart           = 0b1_00000_01, /// start of alternation group  (length)
    OrEnd             = 0b1_00000_10, /// end of the or group (length,mergeIndex)
    //with this instruction order
    //bit mask 0b1_00001_00 could be used to test/set greediness
    InfiniteStart     = 0b1_00001_01, /// start of an infinite repetition x* (length)
    InfiniteEnd       = 0b1_00001_10, /// end of infinite repetition x* (length,mergeIndex)
    InfiniteQStart    = 0b1_00010_01, /// start of a non eager infinite repetition x*? (length)
    InfiniteQEnd      = 0b1_00010_10, /// end of non eager infinite repetition x*? (length,mergeIndex)
    RepeatStart       = 0b1_00011_01, /// start of a {n,m} repetition (length)
    RepeatEnd         = 0b1_00011_10, /// end of x{n,m} repetition (length,step,minRep,maxRep)
    RepeatQStart      = 0b1_00100_01, /// start of a non eager x{n,m}? repetition (length)
    RepeatQEnd        = 0b1_00100_10, /// end of non eager x{n,m}? repetition (length,step,minRep,maxRep)
    //
    LookaheadStart    = 0b1_00110_01, /// begin of the lookahead group (length)
    LookaheadEnd      = 0b1_00110_10, /// end of a lookahead group (length)
    NeglookaheadStart = 0b1_00111_01, /// start of a negative lookahead (length)
    NeglookaheadEnd   = 0b1_00111_10, /// end of a negative lookahead (length)
    LookbehindStart   = 0b1_01000_01, /// start of a lookbehind (length)
    LookbehindEnd     = 0b1_01000_10, /// end of a lookbehind (length)
    NeglookbehindStart= 0b1_01001_01, /// start of a negative lookbehind (length)
    NeglookbehindEnd  = 0b1_01001_10, /// end of negative lookbehind (length)
    //TODO: ...
}
/// a shorthand for IR length - full length of specific opcode evaluated at compile time
template IRL(IR code)
{
    enum IRL =  lengthOfIR(code);
}

/// how many parameters follow the IR, should be optimized fixing some IR bits
int immediateParamsIR(IR i){
    switch (i){
    case IR.OrEnd,IR.InfiniteEnd,IR.InfiniteQEnd:
        return 1;
    case IR.RepeatEnd,IR.RepeatQEnd:
        return 3;
    default:
        return 0;
    }
}
/// full length of IR instruction inlcuding all parameters that might follow it
int lengthOfIR(IR i)
{
    return 1 + immediateParamsIR(i);
}
/// full length of the paired IR instruction inlcuding all parameters that might follow it
int lengthOfPairedIR(IR i)
{
    return 1 + immediateParamsIR(pairedIR(i));
}
/// if the operation has a merge point (this relies on the order of the ops)
bool hasMerge(IR i)
{
    return (i&0b11)==0b10 && i<=IR.InfiniteQEnd;
}
/// is an IR that opens a "group"
bool isStartIR(IR i)
{
    return (i&0b11)==0b01;
}
/// is an IR that ends a "group"
bool isEndIR(IR i)
{
    return (i&0b11)==0b10;
}
/// is a standalone IR
bool isAtomIR(IR i)
{
    return (i&0b11)==0b00;
}
/// makes respective pair out of IR i, swapping start/end bits of instruction
IR pairedIR(IR i)
{
    assert(isStartIR(i) || isEndIR(i));
    return cast(IR)(i ^ 0b11);
}

/// encoded IR instruction
struct Bytecode
{
    uint raw;
    enum MaxSequence = 2+4;
    this(IR code, uint data)
    {
        assert(data < (1<<24) && code < 256);
        raw = code<<24 | data;
    }
    this(IR code, uint data, uint seq)
    {
        assert(data < (1<<22) && code < 256 );
        assert(seq >= 2 && seq < MaxSequence);
        raw = code<<24 | ((seq-2)<<22) | data;
    }
    static Bytecode fromRaw(uint data)
    {
        Bytecode t;
        t.raw = data;
        return t;
    }
    ///bit twiddling helpers
    @property uint data() const { return raw & 0x003f_ffff; }
    ///ditto
    @property uint sequence() const { return 2+((raw >>22) & 0x3); }
    ///ditto
    @property IR code() const { return cast(IR)(raw>>24); }
    ///ditto
    @property bool hotspot() const { return hasMerge(code); }
    ///test the class of this instruction
    @property bool isAtom() const { return isAtomIR(code); }
    ///ditto
    @property bool isStart() const { return isStartIR(code); }
    ///ditto
    @property bool isEnd() const { return isEndIR(code); }
    /// number of arguments
    @property int args() const { return immediateParamsIR(code); }
    /// human readable name of instruction
    @property string mnemonic() const
    {
        return to!string(code);
    }
    /// full length of instruction
    @property uint length() const
    {
        return lengthOfIR(code);
    }
    /// full length of respective start/end of this instruction
    @property uint pairedLength() const
    {
        return lengthOfPairedIR(code);
    }
    ///returns bytecode of paired instruction (assuming this one is start or end)
    @property Bytecode paired() const
    {//depends on bit and struct layout order
        assert(isStart || isEnd);
        return Bytecode.fromRaw(raw ^ (0b11<<24));
    }
    /// gets an index into IR block of the respective pair
    uint indexOfPair(uint pc) const
    {
        assert(isStart || isEnd);
        return isStart ? pc + data + length  : pc - data - lengthOfPairedIR(code);
    }
}

static assert(Bytecode.sizeof == 4);

/// debugging tool, prints out instruction along with opcodes
string disassemble(in Bytecode[] irb, uint pc, in NamedGroup[] dict=[])
{
    auto output = appender!string();
    formattedWrite(output,"%s", irb[pc].mnemonic);
    switch(irb[pc].code)
    {
    case IR.Char:
        formattedWrite(output, " %s (0x%x)",cast(dchar)irb[pc].data, irb[pc].data);
        break;
    case IR.OrChar:
        formattedWrite(output, " %s (0x%x) seq=%d", cast(dchar)irb[pc].data, irb[pc].data, irb[pc].sequence);
        break;
    case IR.RepeatStart, IR.InfiniteStart, IR.Option, IR.GotoEndOr, IR.OrStart:
        //forward-jump instructions
        uint len = irb[pc].data;
        formattedWrite(output, " pc=>%u", pc+len+1);
        break;
    case IR.RepeatEnd, IR.RepeatQEnd: //backward-jump instructions
        uint len = irb[pc].data;
        formattedWrite(output, " pc=>%u min=%u max=%u step=%u",
                pc-len, irb[pc+2].raw, irb[pc+3].raw, irb[pc+1].raw);
        break;
    case IR.InfiniteEnd, IR.InfiniteQEnd, IR.OrEnd: //ditto
        uint len = irb[pc].data;
        formattedWrite(output, " pc=>%u", pc-len);
        break;
    case  IR.LookaheadEnd, IR.NeglookaheadEnd: //ditto
        uint len = irb[pc].data;
        formattedWrite(output, " pc=>%u", pc-len);
        break;
    case IR.GroupStart, IR.GroupEnd:
        uint n = irb[pc].data;
        // Ouch: '!vthis->csym' on line 713 in file 'glue.c'
        //auto ng = find!((x){ return x.group == n; })(dict);
        string name;
        foreach(v;dict)
            if(v.group == n)
            {
                name = "'"~v.name~"'";
                break;
            }
        formattedWrite(output, " %s #%u ",
                name, n);
        break;
    case IR.LookaheadStart, IR.NeglookaheadStart, IR.LookbehindStart, IR.NeglookbehindStart:
        uint len = irb[pc].data;
        formattedWrite(output, " pc=>%u", pc + len + 1);
        break;
    case IR.Backref: case IR.Charset: case IR.Trie:
        uint n = irb[pc].data;
        formattedWrite(output, " %u",  n);
        break;
    default://all data-free instructions
    }
    if(irb[pc].hotspot)
        formattedWrite(output, " Hotspot %u", irb[pc+1].raw);
    return output.data;
}

/// another pretty printer, writes out the bytecode of a regex and where the pc is
void prettyPrint(Sink,Char=const(char))(Sink sink,const(Bytecode)[] irb, uint pc=uint.max,int indent=3,size_t index=0)
    if (isOutputRange!(Sink,Char))
{
    while(irb.length>0){
        formattedWrite(sink,"%3d",index);
        if (pc==0 && irb[0].code!=IR.Char){
            for (int i=0;i<indent-2;++i)
                put(sink,"=");
            put(sink,"> ");
        } else {
            if (isEndIR(irb[0].code)){
                indent-=2;
            }
            if (indent>0){
                string spaces="             ";
                put(sink,spaces[0..(indent%spaces.length)]);
                for (size_t i=indent/spaces.length;i>0;--i)
                    put(sink,spaces);
            }
        }
        if (irb[0].code==IR.Char)
        {
            put(sink,`"`);
            int i=0;
            do{
                put(sink,cast(char[])([cast(dchar)irb[i].data]));
                ++i;
            } while(i<irb.length && irb[i].code==IR.Char);
            put(sink,"\"");
            if (pc<i){
                put(sink,"\n");
                for (int ii=indent+pc+1;ii>0;++ii)
                    put(sink,"=");
                put(sink,"^");
            }
            index+=i;
            irb=irb[i..$];
        } else {
            put(sink,irb[0].mnemonic);
            put(sink,"(");
            formattedWrite(sink,"%d",irb[0].data);
            int nArgs= irb[0].args;
            for (int iarg=0;iarg<nArgs;++iarg){
                if (iarg+1<irb.length){
                    formattedWrite(sink,",%d",irb[iarg+1].data);
                } else {
                    put(sink,"*error* incomplete irb stream");
                }
            }
            put(sink,")");
            if (isStartIR(irb[0].code)){
                indent+=2;
            }
            index+=lengthOfIR(irb[0].code);
            irb=irb[lengthOfIR(irb[0].code)..$];
        }
        put(sink,"\n");
    }
}

static void insertInPlaceAlt(T)(ref T[] arr, size_t idx, T[] items...)
{
   if(__ctfe)
       arr = arr[0..idx] ~ items ~ arr[idx..$];
    else
        insertInPlace(arr, idx, items);
}

static void replaceInPlaceAlt(T)(ref T[] arr, size_t from, size_t to, T[] items...)
{
    //if(__ctfe)
        arr = arr[0..from]~items~arr[to..$];
    /*else //BUG in replaceInPlace?
        replaceInPlace(arr, from, to, items);*/
}

//do not reorder this list
///Regular expression engine/parser options:
/// global - search  nonoverlapping matches in input
/// casefold - case insensitive matching, do casefolding on match in unicode mode
/// freeform - ignore whitespace in pattern, to match space use [ ] or \s
enum RegexOption: uint { global = 0x1, casefold = 0x2, freeform = 0x4, nonunicode = 0x8,  };
private enum NEL = '\u0085', LS = '\u2028', PS = '\u2029'; 
//multiply-add, throws exception on overflow
uint checkedMulAdd(uint f1, uint f2, uint add)
{
    ulong r = f1 * cast(ulong)f2 + add;
    if(r < (1<<32UL))
        throw new RegexException("Regex internal errror - integer overflow");
    return cast(uint)r;
}

/// test if a given string starts with hex number of maxDigit that's a valid codepoint
/// returns it's value and skips these maxDigit chars on success, throws on failure
dchar parseUniHex(Char)(ref Char[] str, uint maxDigit)
{
    enforce(str.length >= maxDigit,"incomplete escape sequence");        
    uint val;
    for(int k=0;k<maxDigit;k++)
    {
        auto current = str[k];//accepts ascii only, so it's OK to index directly
        if('0' <= current && current <= '9')
            val = val * 16 + current - '0';
        else if('a' <= current && current <= 'f')
            val = val * 16 + current -'a' + 10;
        else if('A' <= current && current <= 'Z')
            val = val * 16 + current - 'A' + 10;
        else
            throw new Exception("invalid escape sequence");
    }
    enforce(val <= 0x10FFFF, "invalid codepoint");
    str = str[maxDigit..$];
    return val;
}
///index entry structure for name --> number of submatch
struct NamedGroup
{
    string name;
    uint group;
}
///holds pir of start-end markers for a submatch
struct Group
{
    size_t begin, end;
    string toString() const
    {
        auto a = appender!string();
        formattedWrite(a, "%s..%s", begin, end);
        return a.data;
    }
}

/// structure representing interval: [a,b)
struct Interval
{
    ///
    struct
    {
        uint begin, end;
    }

    ///
    this(uint x)
    {
        begin = x;
        end = x+1;
    }
    ///from [a,b]
    this(uint x, uint y)
    {
        assert(x <= y);
        begin = x;
        end = y+1;
    }
    ///
    string toString()const
    {
        auto s = appender!string;
        formattedWrite(s,"%s(%s)..%s(%s)",
                       begin, ascii.isGraphical(begin) ? to!string(cast(dchar)begin) : "",
                       end, ascii.isGraphical(end) ? to!string(cast(dchar)end) : "");
        return s.data;
    }

}

/// basic internal data structure for [...] sets
struct Charset
{
//private:
    enum uint endOfRange = 0x110000;
    uint[] ivals;
    ///
public:
    ref add(Interval inter)
    {
         debug(fred_charset) writeln("Inserting ",inter);
        if(ivals.empty)
        {
            insertInPlaceAlt(ivals, 0, inter.begin, inter.end);
            return this;
        }
        auto svals = assumeSorted(ivals);
        auto s = svals.lowerBound(inter.begin).length;
        auto e = svals.lowerBound(inter.end).length;//TODO: could do slightly better
        debug(fred_charset)  writeln("Indexes: ", s,"  ", e);
        if(s & 1)
        {
            inter.begin = ivals[s-1];
            s ^= 1;
        }
        if(e & 1)
        {
            inter.end = ivals[e];
            e += 1;
        }
        else //e % 2 == 0
        {
            if(e < ivals.length && inter.end == ivals[e])
            {
                    inter.end = ivals[e+1];
                    e+=2;
            }
        }
        for(size_t i=1;i<ivals.length; i++)
            assert(ivals[i-1] < ivals[i]);
        debug(fred_charset) writeln("Before ", ivals);
        replaceInPlaceAlt(ivals, s, e, inter.begin ,inter.end);
        debug(fred_charset) writeln("After", ivals);
        return this;
    }
    ///
    ref add(dchar ch){ add(Interval(cast(uint)ch)); return this; }
    /// this = this || set
    ref add(in Charset set)//TODO: more effective
    {
        debug(fred_charset) writef ("%s || %s --> ", ivals, set.ivals);
        for(size_t i=0; i<set.ivals.length; i+=2)
            add(Interval(set.ivals[i], set.ivals[i+1]-1));
        debug(fred_charset) writeln(ivals);
        return this;
    }
    /// this = this -- set
    ref sub(in Charset set)
    {
        if(empty)
        {
            ivals = [];
            return this;
        }
        if(set.empty)
            return this;
        auto a = cast(Interval[])ivals;
        auto b = cast(const(Interval)[])set.ivals;
        Interval[] result;
        while(!a.empty && !b.empty)
        {
            if(a.front.end < b.front.begin)
            {
                result ~= a.front;
                a.popFront();
            }
            else if(a.front.begin > b.front.end)
            {
                b.popFront();
            }
            else //there is an intersection
            {
                if(a.front.begin < b.front.begin)
                {
                    result ~= Interval(a.front.begin, b.front.begin-1);
                    if(a.front.end < b.front.end)
                    {
                        a.popFront();
                    }
                    else if(a.front.end > b.front.end)
                    {
                        //adjust a in place
                        a.front.begin = b.front.end;
                        if(a.front.begin >= a.front.end)
                            a.popFront();
                        b.popFront();
                    }
                    else //==
                    {
                        a.popFront();
                        b.popFront();
                    }
                }
                else //a.front.begin > b.front.begin
                {//adjust in place
                    if(a.front.end < b.front.end)
                    {
                        a.popFront();
                    }
                    else
                    {
                        a.front.begin = b.front.end;
                        if(a.front.begin >= a.front.end)
                            a.popFront();
                        b.popFront();
                    }
                }
            }
        }
        result ~= a;//+ leftover of original
        ivals = cast(uint[])result;
        return this;
    }
    /// this = this ~~ set (i.e. (this || set) -- (this && set))
    void symmetricSub(in Charset set)
    {
        auto a = Charset(ivals.dup);
        a.intersect(set);
        this.add(set);
        this.sub(a);
    }
    /// this = this && set
    ref intersect(in Charset set)
    {
        if(empty || set.empty)
        {
            ivals = [];
            return this;
        }
        Interval[] intersection;
        auto a = cast(const(Interval)[])ivals;
        auto b = cast(const(Interval)[])set.ivals;
        for(;;)
        {
            if(a.front.end < b.front.begin)
            {
                a.popFront();
                if(a.empty)
                    break;
            }
            else if(a.front.begin > b.front.end)
            {
                b.popFront();
                if(b.empty)
                    break;
            }
            else //there is an intersection
            {
                if(a.front.end < b.front.end)
                {
                    intersection ~= Interval(max(a.front.begin, b.front.begin), a.front.end);
                    a.popFront();
                    if(a.empty)
                        break;
                }
                else if(a.front.end > b.front.end)
                {
                    intersection ~= Interval(max(a.front.begin, b.front.begin), b.front.end);
                    b.popFront();
                    if(b.empty)
                        break;
                }
                else //==
                {
                    intersection ~= Interval(max(a.front.begin, b.front.begin), a.front.end);
                    a.popFront();
                    b.popFront();
                    if(a.empty || b.empty)
                        break;
                }
            }
        }
        ivals = cast(uint[])intersection;
        return this;
    }
    /// this = !this (i.e. [^...] in regex syntax)
    ref negate()
    {
        if(empty)
        {
            insertInPlaceAlt(ivals, 0, 0u, endOfRange);
            return this;
        }
        if(ivals[0] != 0)
            insertInPlaceAlt(ivals, 0, 0u);
        else
        {
            for(size_t i=1; i<ivals.length; i++)
                ivals[i-1] = ivals[i];//moveAll(ivals[1..$], ivals[0..$-1]);
            ivals = ivals[0..$-1];
            //assumeSafeAppend(ivals);
        }
        if(ivals[$-1] != endOfRange)
            insertInPlaceAlt(ivals, ivals.length, endOfRange);
        else
        {
            ivals = ivals[0..$-1] ;
            //assumeSafeAppend(ivals);
        }
        assert(!(ivals.length & 1));
        return this;
    }
    /// test if ch is present in this set
    bool opIndex(dchar ch) const
    {
        //debug(fred_charset) writeln(ivals);
        auto svals = assumeSorted!"a <= b"(ivals);
        auto s = svals.lowerBound(cast(uint)ch).length;
        //debug(fred_charset) writeln("Test at ", fnd);
        return s & 1;
    }
    /// true if set is empty
    @property bool empty() const {   return ivals.empty; }
    /// print out in [\uxxxx-\uyyyy...] style
    void printUnicodeSet(void delegate(const(char)[])sink) const
    {
        sink("[");
        for(uint i=0;i<ivals.length; i+=2)
            if(ivals[i] + 1 == ivals[i+1])
                formattedWrite(sink, "\\U%08x", ivals[i]);
            else
                formattedWrite(sink, "\\U%08x-\\U%08x", ivals[i], ivals[i+1]-1);
        sink("]");
    }
    /// deep copy this Charset
    @property Charset dup() const
    {
        return Charset(ivals.dup);
    }
    /// full range from start to end
    @property uint extent() const
    {
        return ivals.empty ? 0 : ivals[$-1] - ivals[0];
    }
    /// number of codepoints in this charset
    @property uint chars() const
    {
        //CTFE workaround
        uint ret;
        for(uint i=0; i<ivals.length; i+=2)
            ret += ivals[i+1] - ivals[i];
        return ret;
    }
    /// troika for hash map
    bool opEquals(ref const Charset set) const
    {
        return ivals == set.ivals;
    }
    ///ditto
    int opCmp(ref const Charset set) const
    {
        return cmp(cast(const(uint)[])ivals, cast(const(uint)[])set.ivals);
    }
    ///ditto
    hash_t toHash() const
    {
        hash_t hash = 5381+7*ivals.length;
        if(!empty)
            hash = 31*ivals[0] + 17*ivals[$-1];
        return hash;
    }
    struct Range
    {
        const(uint)[] ivals;
        uint j;
        this(in Charset set)
        {
            ivals = set.ivals;
            if(!empty)
                j = ivals[0];
        }
        @property bool empty() const { return ivals.empty; }
        @property uint front() const
        {
            assert(!empty);
            return j; 
        }
        void popFront()
        {
            assert(!empty);
            if(++j >= ivals[1])
            {
                ivals = ivals[2..$];
                if(!empty)
                    j = ivals[0];
            }
        }
    }
    static assert(isInputRange!Range);
    Range opSlice() const
    {
        return Range(this);
    }
}
///
struct BasicTrie(uint prefixBits)
    if(prefixBits > 4)
{
    enum prefixWordBits = prefixBits-2, prefixSize=1<<prefixBits,
        prefixWordSize = 1<<(prefixBits-2),  
        bitTestShift = prefixBits+3, prefixMask = (1<<prefixBits)-1;
    static assert(prefixBits > uint.sizeof);
    uint[] data;
    ushort[] indexes;
    bool negative;
    //
    static void printBlock(in uint[] block)
    {
        for(uint k=0; k<prefixSize; k++)
        {
            if((k & 15) == 0)
                write(" ");
            if((k & 63) == 0)
                writeln();
            writef("%d", bt(block.ptr, k) != 0);
        }
        writeln();
    }
    /// create a trie from charset set
    this(in Charset s)
    {
        if(s.empty)
            return;
        const(Charset) set = s.chars > 500_000 ? (negative=true, s.dup.negate) : s;
        uint bound = 0;//set up on first iteration
        ushort emptyBlock = ushort.max;
        auto ivals  = set.ivals;
        uint[prefixWordSize] page;
        for(uint i=0; i<Charset.endOfRange; i+= prefixSize)
        {
            if(i+prefixSize > ivals[bound] || emptyBlock == ushort.max)//avoid empty blocks if we have one already
            {
                bool flag = true;
            L_Prefix_Loop:
                for(uint j=0; j<prefixSize; j++)
                {
                    while(i+j >= ivals[bound+1])
                    {
                        bound += 2;
                        if(bound == ivals.length)
                        {
                            bound = uint.max;
                            if(flag)//not a single one set so far
                                return;
                            // no more bits in the whole set, but need to add the last bucket
                            break L_Prefix_Loop;
                        }
                    }
                    if(i+j >= ivals[bound])
                    {
                        page[j>>5] |=  1<<(j & 31);// 32 = uint.sizeof*8
                        flag = false;
                    }
                }
                
                debug(fred_trie)
                {
                   printBlock(page);
                }
                //writeln("Iteration ", i>>prefixBits);
                uint npos;
                for(npos=0;npos<data.length;npos+=prefixWordSize)
                    if(equal(page[], data[npos .. npos+prefixWordSize]))
                    {
                        indexes ~= cast(ushort)(npos>>prefixWordBits);
                        break;
                    }
                if(npos == data.length)
                {
                    indexes ~= cast(ushort)(data.length>>prefixWordBits);
                    data ~= page;
                    if(flag)
                        emptyBlock = indexes[$-1];
                }
                if(bound == uint.max)
                    break;
                page[] = 0;
            }
            else//fast reroute whole blocks to an empty one
            {
                indexes ~= emptyBlock;
            }
        }
    }
    ///debugging tool
    void desc() const
    {
        writeln(indexes);
        writeln("***Blocks***");
        for(uint i=0; i<data.length; i+=prefixWordSize)
        {
            printBlock(data[i .. i+prefixWordSize]);
            writeln("---");
        }
    }
    /// != 0 if contains char ch
    bool opIndex(dchar ch) const
    {
        assert(ch < 0x110000);
        uint ind = ch>>prefixBits;
        if(ind >= indexes.length)
            return negative;
        return cast(bool)bt(data.ptr, (indexes[ch>>prefixBits]<<bitTestShift)+(ch&prefixMask)) ^ negative;
    }
    ///get a negative copy
    auto negated() const
    {
        BasicTrie t = cast(BasicTrie)this;//shallow copy, need to subvert type system?
        t.negative = !negative; 
        return t;
    }
}

alias BasicTrie!8 Trie;
Trie[const(Charset)] trieCache;

Trie getTrie(in Charset set)
{
    if(__ctfe)
        return Trie(set);
    else
    {
        auto p = set in trieCache;
        if(p)
            return *p;
        return (trieCache[set] = Trie(set));
    }
}

//version(fred_trie_test)
unittest//a very sloow test
{
    uint max_char, max_data;
    Trie t;
    auto x = wordCharacter;
    
    Charset set;
    set.add(unicodeAlphabetic);
    for(size_t i=1;i<set.ivals.length; i++)
        assert(set.ivals[i-1] <= set.ivals[i],text(set.ivals[i-1], "  ",set.ivals[i]));
    t = wordTrie.negated;
    assert(!t['a']);
    assert(t[' ']);
    foreach(up; unicodeProperties)
    {
        t = Trie(up.set);
        foreach(uint ch; up.set[])
            assert(t[ch], text("on ch ==", ch));
        auto s = up.set.dup.negate.negate;
        assert(equal(cast(immutable(Interval)[])s.ivals, cast(immutable(Interval)[])up.set.ivals));
        foreach(ch; up.set.dup.negate[])
        {
            assert(!t[ch], text("negative on ch ==", ch));
        }
    }
}

/// fussy compare for unicode property names as per UTS-18
int comparePropertyName(Char)(const(Char)[] a, const(Char)[] b)
{
    for(;;)
    {
        while(!a.empty && (isWhite(a.front) || a.front == '-' || a.front =='_'))
        {
            a.popFront();
        }
        while(!b.empty && (isWhite(b.front) || b.front == '-' || b.front =='_'))
        {
            b.popFront();
        }
        if(a.empty)
            return b.empty ? 0 : -1;
        if(b.empty)
            return 1;
        auto ca = toLower(a.front), cb = toLower(b.front);
        if(ca > cb)
            return 1;
        else if( ca < cb)
            return -1;
        a.popFront();
        b.popFront();
    }
}
///ditto
bool propertyNameLess(Char)(const(Char)[] a, const(Char)[] b)
{
	return comparePropertyName(a, b) < 0;
}

unittest
{
    assert(comparePropertyName("test","test") == 0);
    assert(comparePropertyName("Al chemical Symbols", "Alphabetic Presentation Forms") == -1);
    assert(comparePropertyName("Basic Latin","basic-LaTin") == 0);
}

///Gets array of all of common case eqivalents of given codepoint (fills provided array & returns a slice of it)
dchar[] getCommonCasing(dchar ch, dchar[] range)
{
    assert(range.length >= 5);
    range[0] = ch;
    if(evenUpper[ch])//simple version
    {
        range[1] = ch ^ 1;
        return range[0..2];
    }
    uint s = 0, n = 1;
    for(s=0;s < n; s++)
    {
        foreach(i, v; commonCaseTable)
            if(v.set[range[s]] && !canFind(range[0..n], range[s]+cast(int)v.delta))
            {

                range[n++] = range[s]+v.delta;
            }
        auto f = countUntil(casePairs, range[s]);
        if(f >=0)
            while(1)
            {
                if(!canFind(range[0..n], casePairs[f^1]))
                {
                   range[n++] = casePairs[f^1];
                }
                f++;
                auto next =  countUntil(casePairs[f..$], range[s]);
                if(next < 0)
                    break;
                f += next;
            }
    }
    return range[0..n];
}

unittest
{
    dchar[6] data;
    //these values give 100% code coverage for getCommonCasing
    assert(getCommonCasing(0x01BC, data) == [0x01bc, 0x01bd]);
    assert(getCommonCasing(0x03B9, data) == [0x03b9, 0x0399, 0x0345, 0x1fbe]);
    assert(getCommonCasing(0x10402, data) == [0x10402, 0x1042a]);
}

//property for \w character class
@property Charset wordCharacter()
{
    return memoizeExpr!("Charset.init.add(unicodeAlphabetic).add(unicodeMn).add(unicodeMc)
        .add(unicodeMe).add(unicodeNd).add(unicodePc)")();
}
@property Trie wordTrie()
{
    return memoizeExpr!("Trie(wordCharacter)")();
}

auto memoizeExpr(string expr)()
{
    if(__ctfe)
        return mixin(expr);
    alias typeof(mixin(expr)) T;
    static T slot;
    if(slot == T.init)
        slot =  mixin(expr);
    return slot;
}
/++
    fetch codepoint set corresponding to a name (InBlock or binary property)
+/
const(Charset) getUnicodeSet(in char[] name, bool negated)
{
    alias comparePropertyName ucmp;
    Charset s;
    
    //unicode property
    //helper: direct access with a sanity check
    static void addTest(ref Charset set, int delta, uint index)
    {
        assert(commonCaseTable[index].delta == delta, text(commonCaseTable[index].delta," vs ", delta));
        set.add(commonCaseTable[index].set);
    }  
    if(ucmp(name, "L") == 0 || ucmp(name, "Letter") == 0)
    {
        s.add(evenUpper);
        foreach(v; commonCaseTable)
            s.add(v.set);
        foreach(v; casePairs)
            s.add(v);
        s.add(unicodeLt).add(unicodeLo).add(unicodeLm);
    }
    else if(ucmp(name,"LC") == 0 || ucmp(name,"Cased Letter")==0)
    {
        s.add(evenUpper);
        foreach(v; commonCaseTable)
            s.add(v.set);
        foreach(v; casePairs)
            s.add(v);
        s.add(unicodeLt);//Title case
    }
    else if(ucmp(name,"Ll") == 0 || ucmp(name,"Lowercase Letter")==0)
    {
        foreach(ch; evenUpper[])
            if(ch & 1)
                s.add(ch);   
        addTest(s,   8, 0);
        addTest(s, -32, 7);
        addTest(s, -37, 9);
        addTest(s, -40, 11);
        addTest(s, -48, 13);
        addTest(s, -63, 15);
        addTest(s,  74, 16);
        addTest(s, -80, 19);
        addTest(s,  86, 20);
        addTest(s, 100, 22);
        addTest(s, 112, 24);
        addTest(s, 126, 26);
        addTest(s, 128, 28);
        addTest(s, 130, 30);
        addTest(s,-205, 33);
        addTest(s,-217, 35);
        addTest(s,-7264, 37);
        addTest(s,10815, 38);   
    }
    else if(ucmp(name,"Lu") == 0 || ucmp(name,"Uppercase Letter")==0)
    {
        foreach(ch; evenUpper[])
            if(!(ch & 1))
                s.add(ch);
        addTest(s,  -8, 1);
        addTest(s,  32, 6);
        addTest(s,  37, 8);
        addTest(s,  40, 10);
        addTest(s,  48, 12);
        addTest(s,  63, 14);
        addTest(s, -74, 17);
        addTest(s,  80, 18);
        addTest(s, -86, 21);
        addTest(s,-100, 23);
        addTest(s,-112, 25);
        addTest(s,-126, 27);
        addTest(s,-128, 29);
        addTest(s,-130, 31);
        addTest(s, 205, 32);
        addTest(s, 217, 34);
        addTest(s, 7264, 36);
        addTest(s,-10815, 39); 
    }
    else if(ucmp(name, "M") == 0 || ucmp(name, "Mark") == 0)
    {
        s.add(unicodeMn).add(unicodeMc).add(unicodeMe);
    }
    else if(ucmp(name, "P") == 0 || ucmp(name, "Punctuation") == 0)
    {
        s.add(unicodePc).add(unicodePd).add(unicodePs).add(unicodePe)
            .add(unicodePi).add(unicodePf).add(unicodePo);
    }
    else if(ucmp(name, "S") == 0 || ucmp(name, "Symbol") == 0)
    {
        s.add(unicodeSm).add(unicodeSc).add(unicodeSk).add(unicodeSo);
    }
    else if(ucmp(name, "Z") == 0 || ucmp(name, "Separator") == 0)
    {
        s.add(unicodeZs).add(unicodeZl).add(unicodeZp);
    }
    else if(ucmp(name, "C") == 0 || ucmp(name, "Other") == 0)
    {
        s.add(unicodeCo).add(unicodeLo).add(unicodeNo)
            .add(unicodeSo).add(unicodePo);
    }
    else if(ucmp(name, "any") == 0)
        s.add(Interval(0,0x10FFFF));
    else if(ucmp(name, "ascii") == 0)
        s.add(Interval(0,0x7f));
    else
    {
        version(fred_perfect_hashing)
        {
            uint key = phash(name);
            if(key >= PHASHNKEYS || ucmp(name,unicodeProperties[key].name) != 0)
                enforce(0, "invalid property name");
            s = cast(Charset)unicodeProperties[key].set;
        }
        else
        {
            auto range = assumeSorted!((x,y){ return ucmp(x.name, y.name) < 0; })(unicodeProperties); 
            auto eq = range.lowerBound(UnicodeProperty(cast(string)name,Charset.init)).length;//TODO: hackish
            enforce(eq!=range.length && ucmp(name,range[eq].name)==0,"invalid property name");
            s = cast(Charset)range[eq].set;
            /*auto idx = bsearch(unicodeProperties, immutable(UnicodeProperty)(cast(string)name,Charset.init));
            enforce(idx != uint.max,"invalid property name");
            s = cast(Charset)unicodeProperties[idx].set;*/
        }
    }
    if(negated)
    {
		s = s.dup;//tables are immutable
        s.negate();
    }
    return cast(const Charset)s;
}

/// basic stack, just in case it gets used anywhere else then Parser
struct Stack(T, bool CTFE=false)
{
    static if(!CTFE)
        Appender!(T[]) stack;//compiles but bogus at CTFE
    else
    {
        struct Proxy
        { 
            T[] data;
            void put(T val)
            { 
                data ~= val;
            }
            void shrinkTo(size_t sz){   data = data[0..sz]; }
        }
        Proxy stack;
    }
    @property bool empty(){ return stack.data.empty; }
    void push(T item)
    {
        stack.put(item);
    }
    @property ref T top()
    {
        assert(!empty);
        return stack.data[$-1];
    }
    @property void top(T val)
    {
        assert(!empty);
        stack.data[$-1] = val;
    }
    @property size_t length() {  return stack.data.length; }
    T pop()
    {
        assert(!empty);
        auto t = stack.data[$-1];
        stack.shrinkTo(stack.data.length-1);
        return t;
    }
}

struct Parser(R, bool CTFE=false)
    if (isForwardRange!R && is(ElementType!R : dchar))
{
    enum infinite = ~0u;
    dchar _current;
    bool empty;
    R pat, origin;       //keep full pattern for pretty printing error messages
    Bytecode[] ir;       //resulting bytecode
    uint re_flags = 0;   //global flags e.g. multiline + internal ones
    Stack!(uint,CTFE) fixupStack;  //stack of opened start instructions
    NamedGroup[] dict;   //maps name -> user group number
    //current num of group, group nesting level and repetitions step
    uint ngroup = 1, nesting = 0;
    uint counterDepth = 0; //current depth of nested counted repetitions
    const(Charset)[] charsets;  //
    const(Trie)[] tries; //
    this(S)(R pattern, S flags)
        if(isSomeString!S)
    {
        pat = origin = pattern;
        if(!__ctfe)
            ir.reserve(pat.length);
        next();
        parseFlags(flags);
        if(__ctfe)
            parseRegex();
        else
        {
            try
            {    
                parseRegex();
            }
            catch(Exception e)
            {
                error(e.msg);//also adds pattern location
            }
        }

    }
    @property dchar current(){ return _current; }
    bool next()
    {
        if(pat.empty)
        {
            empty =  true;
            return false;
        }
        if(__ctfe)
        {
            size_t idx=0;
            _current = decode(pat, idx);
            pat = pat[idx..$];
        }
        else
        {
            _current = pat.front;
            pat.popFront();
        }
        return true;
    }
    void skipSpace()
    {
        while(isWhite(current) && next()){ }
    }
    void restart(R newpat)
    {
        pat = newpat;
        empty = false;
        next();
    }
    void put(Bytecode code)
    {  
        if(__ctfe)
        {
            ir = ir ~ code;
        }
        else
            ir ~= code; 
    }
    void putRaw(uint number){ ir ~= Bytecode.fromRaw(number); }
    uint parseDecimal()
    {
        uint r=0;
        while(ascii.isDigit(current))
        {
            if(r >= (uint.max/10))
                error("Overflow in decimal number");
            r = 10*r + cast(uint)(current-'0');
            if(!next())
                break;
        }
        return r;
    }
    // parse control code of form \cXXX, c assumed to be the current symbol
    dchar parseControlCode()
    {
        enforce(next(), "Unfinished escape sequence");
        enforce(('a' <= current && current <= 'z') || ('A' <= current && current <= 'Z'),
            "Only letters are allowed after \\c");
        return current & 0x1f;
    }
    /**

    */
    void parseFlags(S)(S flags)
    {
        foreach(ch; flags)//flags are ASCII anyway
        {
            alias TypeTuple!('g', 'i', 'x', 'U') switches;
            switch(ch)
            {
                
                foreach(i, op; __traits(allMembers, RegexOption))
                {
                    case switches[i]:
                            if(re_flags & mixin("RegexOption."~op))
                                throw new RegexException(text("redundant flag specified: ",ch));
                            re_flags |= mixin("RegexOption."~op);
                            break;
                }
                default:
                    new RegexException(text("unknown regex flag '",ch,"'"));
            }
        }
    }
    /**
        Parse and store IR for regex pattern
    */
    void parseRegex()
    {
        fixupStack.push(0);
        auto subSave = ngroup;
        auto maxCounterDepth = counterDepth;
        uint fix;//fixup pointer
        
        while(!empty)
        {
            debug(fred_parser) writeln("*LR*\nSource: ", pat, "\nStack: ",fixupStack.stack.data);

            switch(current)
            {
            case '(':
                next();
                nesting++;
                uint nglob;
                fixupStack.push(cast(uint)ir.length);
                if(current == '?')
                {
                    next();
                    switch(current)
                    {
                    case ':':
                        put(Bytecode(IR.Nop, 0));
                        next();
                        break;
                    case '=':
                        put(Bytecode(IR.LookaheadStart, 0));
                        next();
                        break;
                    case '!':
                        put(Bytecode(IR.NeglookaheadStart, 0));
                        next();
                        break;
                    case 'P':
                        next();
                        if(current != '<')
                            error("Expected '<' in named group");
                        string name;
                        while(next() && isAlpha(current))
                        {
                            name ~= current;
                        }
                        if(current != '>')
                            error("Expected '>' closing named group");
                        next();
                        nglob = ngroup++;
                        auto t = NamedGroup(name, nglob);
                        
                        if(__ctfe)
                        {
                            size_t ind;
                            for(ind=0; ind <dict.length; ind++)
                                if(t.name >= dict[ind].name)
                                    break;
                            insertInPlaceAlt(dict, ind, t);
                        }
                        else
                        {
                            auto d = assumeSorted!"a.name < b.name"(dict);
                            auto ind = d.lowerBound(t).length;
                            insertInPlaceAlt(dict, ind, t);
                        }
                        put(Bytecode(IR.GroupStart, nglob));
                        break;
                    case '<':
                        next();
                        if(current == '=')
                            put(Bytecode(IR.LookbehindStart, 0));
                        else if(current == '!')
                            put(Bytecode(IR.NeglookbehindStart, 0));
                        else
                            error("'!' or '=' expected after '<'");
                        next();
                        break;
                    default:
                        error(" ':', '=', '<', 'P' or '!' expected after '(?' ");
                    }
                }
                else
                {
                    nglob = ngroup++; //put local index
                    put(Bytecode(IR.GroupStart, nglob));
                }
                break;
            case ')':
                enforce(nesting, "Unmatched ')'");
                nesting--;
                next();
                fix = fixupStack.pop();
                switch(ir[fix].code)
                {
                case IR.GroupStart:
                    put(Bytecode(IR.GroupEnd,ir[fix].data));
                    parseQuantifier(fix);
                    break;
                case IR.LookaheadStart, IR.NeglookaheadStart, IR.LookbehindStart, IR.NeglookbehindStart:
                    ir[fix] = Bytecode(ir[fix].code, ir.length - fix - 1);
                    put(ir[fix].paired);
                    break;
                case IR.Option: // | xxx )
                    // two fixups: last option + full OR
                    finishAlternation(fix);
                    fix = fixupStack.top;
                    switch(ir[fix].code)
                    {
                    case IR.GroupStart:
                        fixupStack.pop();
                        put(Bytecode(IR.GroupEnd,ir[fix].data));
                        parseQuantifier(fix);
                        break;
                    case IR.LookaheadStart, IR.NeglookaheadStart, IR.LookbehindStart, IR.NeglookbehindStart:
                        fixupStack.pop();
                        ir[fix] = Bytecode(ir[fix].code, ir.length - fix - 1);
                        put(ir[fix].paired);
                        break;
                    default://(?:xxx)
                        fixupStack.pop();
                        parseQuantifier(fix);
                    }
                    break;
                default://(?:xxx)
                    parseQuantifier(fix);
                }
                break;
            case '|':
                next();
                fix = fixupStack.top;
                if(ir.length > fix && ir[fix].code == IR.Option)
                {
                    ir[fix] = Bytecode(ir[fix].code, ir.length - fix);
                    put(Bytecode(IR.GotoEndOr, 0));
                    fixupStack.top = ir.length; // replace latest fixup for Option
                    put(Bytecode(IR.Option, 0));
                    break;
                }
                //start a new option
                //CTFE workaround
                if(fixupStack.stack.data.length == 1)//only root entry
                    fix = -1;
                uint len = ir.length - fix;
                insertInPlaceAlt(ir, fix+1, Bytecode(IR.OrStart, 0), Bytecode(IR.Option, len));
                assert(ir[fix+1].code == IR.OrStart);
                put(Bytecode(IR.GotoEndOr, 0));
                fixupStack.push(fix+1); // fixup for StartOR
                fixupStack.push(ir.length); //for Option
                put(Bytecode(IR.Option, 0));
                break;
            default://no groups or whatever
                uint start = cast(uint)ir.length;
                parseAtom();
                parseQuantifier(start);
            }
        }
        //unwind fixup stack, check for errors
        //.stack.data. is a workaround for CTFE
        if(fixupStack.stack.data.length != 1)
        {
            fix = fixupStack.pop();
            enforce(ir[fix].code == IR.Option,"LR syntax error");
            finishAlternation(fix);
            //CTFE workaround
            enforce(fixupStack.stack.data.length == 1, "LR syntax error");
        }
    }
    //helper function, finilizes IR.Option, fix points to the first option of sequence
    void finishAlternation(uint fix)
    {
        enforce(ir[fix].code == IR.Option, "LR syntax error");
        ir[fix] = Bytecode(ir[fix].code, ir.length - fix - IRL!(IR.OrStart));
        fix = fixupStack.pop();
        enforce(ir[fix].code == IR.OrStart, "LR syntax error");
        ir[fix] = Bytecode(IR.OrStart, ir.length - fix - IRL!(IR.OrStart));
        put(Bytecode(IR.OrEnd, ir.length - fix - IRL!(IR.OrStart)));
        uint pc = fix + IRL!(IR.OrStart);
        while(ir[pc].code == IR.Option)
        {
            pc = pc + ir[pc].data;
            if(ir[pc].code != IR.GotoEndOr)
                break;
            ir[pc] = Bytecode(IR.GotoEndOr,cast(uint)(ir.length - pc - IRL!(IR.OrEnd)));
            pc += IRL!(IR.GotoEndOr);
        }
        put(Bytecode.fromRaw(0));
    }
    /*
        Parse and store IR for atom-quantifier pair
    */
    void parseQuantifier(uint offset)
    {
        uint replace = ir[offset].code == IR.Nop;
        if(empty && !replace)
            return;
        uint min, max;
        switch(current)
        {
        case '*':
            min = 0;
            max = infinite;
            break;
        case '?':
            min = 0;
            max = 1;
            break;
        case '+':
            min = 1;
            max = infinite;
            break;
        case '{':
            enforce(next(), "Unexpected end of regex pattern");
            enforce(ascii.isDigit(current), "First number required in repetition");
            min = parseDecimal();
            //skipSpace();
            if(current == '}')
                max = min;
            else if(current == ',')
            {
                next();
                if(ascii.isDigit(current))
                    max = parseDecimal();
                else if(current == '}')
                    max = infinite;
                else
                    error("Unexpected symbol in regex pattern");
                skipSpace();
                if(current != '}')
                    error("Unmatched '{' in regex pattern");
            }
            else
                error("Unexpected symbol in regex pattern");
            break;
        default:
            if(replace)
            {
                moveAll(ir[offset+1..$],ir[offset..$-1]);
                ir.length -= 1;
            }
            return;
        }
        uint len = cast(uint)ir.length - offset - replace;
        bool greedy = true;
        //check only if we managed to get new symbol
        if(next() && current == '?')
        {
            greedy = false;
            next();
        }
        if(max != infinite)
        {
            if(min != 1 || max != 1)
            {
                Bytecode op = Bytecode(greedy ? IR.RepeatStart : IR.RepeatQStart, len);
                if(replace)
                    ir[offset] = op;
                else
                    insertInPlaceAlt(ir, offset, op);
                put(Bytecode(greedy ? IR.RepeatEnd : IR.RepeatQEnd, len));
                putRaw(1);
                putRaw(min);
                putRaw(max);
                counterDepth = std.algorithm.max(counterDepth, nesting+1);
            }
        }
        else if(min) // && max is infinite
        {
            if(min != 1)
            {
                Bytecode op = Bytecode(greedy ? IR.RepeatStart : IR.RepeatQStart, len);
                if(replace)
                    ir[offset] = op;
                else
                    insertInPlaceAlt(ir, offset, op);
                offset += 1;//so it still points to the repeated block
                put(Bytecode(greedy ? IR.RepeatEnd : IR.RepeatQEnd, len));
                putRaw(1);
                putRaw(min);
                putRaw(min);
                counterDepth = std.algorithm.max(counterDepth, nesting+1);
            }
            else if(replace)
            {
                if(__ctfe)//CTFE workaround: no moveAll and length -= x;
                {
                    ir = ir[0..offset] ~ ir[offset+1..$];
                }
                else
                {
                    moveAll(ir[offset+1 .. $],ir[offset .. $-1]);
                    ir.length -= 1;
                }
            }
            put(Bytecode(greedy ? IR.InfiniteStart : IR.InfiniteQStart, len));
            ir ~= ir[offset .. offset+len];
            //IR.InfinteX is always a hotspot
            put(Bytecode(greedy ? IR.InfiniteEnd : IR.InfiniteQEnd, len));
            put(Bytecode.init); //merge index
        }
        else//vanila {0,inf}
        {
            Bytecode op = Bytecode(greedy ? IR.InfiniteStart : IR.InfiniteQStart, len);
            if(replace)
                ir[offset] = op;
            else
                insertInPlaceAlt(ir, offset, op);
            //IR.InfinteX is always a hotspot
            put(Bytecode(greedy ? IR.InfiniteEnd : IR.InfiniteQEnd, len));
            put(Bytecode.init); //merge index

        }
    }
    /**
        Parse and store IR for atom
    */
    void parseAtom()
    {
        if(empty)
            return;
        switch(current)
        {
        case '*', '?', '+', '|', '{', '}':
            error("'*', '+', '?', '{', '}' not allowed in atom");
            break;
        case '.':
            put(Bytecode(IR.Any, 0));
            next();
            break;
        case '[':
            parseCharset();
            break;
        case '\\':
            enforce(next(), "Unfinished escape sequence");
            parseEscape();
            break;
        case '^':
            put(Bytecode(IR.Bol, 0));
            next();
            break;
        case '$':
            put(Bytecode(IR.Eol, 0));
            next();
            break;
        default:
            if(re_flags & RegexOption.casefold)
            {
                dchar[5] data;
                auto range = getCommonCasing(current, data);
                if(range.length == 1)
                    put(Bytecode(IR.Char, range[0]));
                else
                    foreach(v; range)
                        put(Bytecode(IR.OrChar, v, range.length));
            }
            else
                put(Bytecode(IR.Char, current));
            next();
        }
    }
    //Charset operations relatively in order of priority
    enum Operator:uint { Open=0, Negate,  Difference, SymDifference, Intersection, Union, None };
    // parse unit of charset spec, most notably escape sequences and char ranges
    // also fetches next set operation
    Tuple!(Charset,Operator) parseCharTerm()
    {
        enum State{ Start, Char, Escape, Dash, DashEscape };
        Operator op = Operator.None;;
        dchar last;
        Charset set;
        State state = State.Start;
        static void addWithFlags(ref Charset set, uint ch, uint re_flags)
        {
            if(re_flags & RegexOption.casefold)
            {
                dchar[5] chars;
                auto range = getCommonCasing(ch, chars);
                foreach(v; range)
                    set.add(v);
            }
            else
                set.add(ch);
        }
        L_CharTermLoop:
        for(;;)
        {
            final switch(state)
            {
            case State.Start:
                switch(current)
                {
                case '[':
                    op = Operator.Union;
                    goto case;
                case ']':
                    break L_CharTermLoop;
                case '\\':
                    state = State.Escape;
                    break;
                default:
                    state = State.Char;
                    last = current;
                }
                break;
            case State.Char:
                switch(current)
                {
                case '|':
                    if(last == '|')
                    {
                        op = Operator.Union;
                        next();
                        break L_CharTermLoop;
                    }
                    goto default;   
                case '-':
                    if(last == '-')
                    {
                        op = Operator.Difference;
                        next();
                        break L_CharTermLoop;
                    }
                    state = State.Dash;
                    break;
                case '~':
                    if(last == '~')
                    {
                        op = Operator.SymDifference;
                        next();
                        break L_CharTermLoop;
                    }
                    goto default;
                case '&':
                    if(last == '&')
                    {
                        op = Operator.Intersection;
                        next();
                        break L_CharTermLoop;
                    }
                    goto default;
                case '\\':
                    set.add(last);
                    state = State.Escape;
                    break;
                case '[':
                    op = Operator.Union;
                    goto case;
                case ']':
                    set.add(last);
                    break L_CharTermLoop;
                default:
                    addWithFlags(set, last, re_flags);
                    last = current;
                }
                break;
            case State.Escape:
                switch(current)
                {
                case 'f':
                    last = '\f';
                    state = State.Char;
                    break;
                case 'n':
                    last = '\n';
                    state = State.Char;
                    break;
                case 'r':
                    last = '\r';
                    state = State.Char;
                    break;
                case 't':
                    last = '\t';
                    state = State.Char;
                    break;
                case 'v':
                    last = '\v';
                    state = State.Char;
                    break;
                case 'c':
                    last = parseControlCode();
                    state = State.Char;
                    break;
                case '\\', '[', ']':
                    last = current;
                    state = State.Char;
                    break;
                case 'p':
                    set.add(parseUnicodePropertySpec(false));
                    state = State.Start;
                    continue L_CharTermLoop; //next char already fetched
                case 'P':
                    set.add(parseUnicodePropertySpec(true));
                    state = State.Start;
                    continue L_CharTermLoop; //next char already fetched
                case 'x':
                    last = parseUniHex(pat, 2);
                    state = State.Char;
                    break;
                case 'u':
                    last = parseUniHex(pat, 4);
                    state = State.Char;
                    break;
                case 'U':
                    last = parseUniHex(pat, 8);
                    state = State.Char;
                    break;                
                case 'd':
                    set.add(unicodeNd);
                    state = State.Start;
                    break;
                case 'D':
                    set.add(unicodeNd.dup.negate);
                    state = State.Start;
                    break;
                case 's':
                    set.add(unicodeWhite_Space);
                    state = State.Start;
                    break;
                case 'S':
                    set.add(unicodeWhite_Space.dup.negate);
                    state = State.Start;
                    break;
                case 'w':
                    set.add(wordCharacter);
                    state = State.Start;
                    break;
                case 'W':
                    set.add(wordCharacter.dup.negate);
                    state = State.Start;
                    break;
                default:
					assert(0);
                }
                break;
            case State.Dash:
                switch(current)
                {
                case '[':
                    op = Operator.Union;
                    goto case;
                case ']':
                    //means dash is a single char not an interval specifier
                    addWithFlags(set, last, re_flags);
                    set.add('-');
                    break L_CharTermLoop;
                 case '-'://set Difference again
                    addWithFlags(set, last, re_flags);
                    op = Operator.Difference;
                    next();//skip '-'
                    break L_CharTermLoop;
                case '\\':
                    state = State.DashEscape;
                    break;
                default:
                    enforce(last <= current, "inverted range");
                    if(re_flags & RegexOption.casefold)
                    {
                        for(uint ch = last; ch <= current; ch++)
                            addWithFlags(set, ch, re_flags);
                    }
                    else
                        set.add(Interval(last, current));
                    state = State.Start;
                }
                break;            
            case State.DashEscape:  // xxxx-\yyyy
                uint end;
                switch(current)
                {
                case 'f':
                    end = '\f';
                    break;
                case 'n':
                    end = '\n';
                    break;
                case 'r':
                    end = '\r';
                    break;
                case 't':
                    end = '\t';
                    break;
                case 'v':
                    end = '\v';
                    break;
                case '\\', '[', ']': 
                    end = current;
                    break;
                case 'c':
                    end = parseControlCode();
                    break;
                case 'x':
                    end = parseUniHex(pat, 2);
                    break;
                case 'u': 
                    end = parseUniHex(pat, 4);
                    break;
                case 'U':
                    end = parseUniHex(pat, 8);
                    break;
                default:
                    error("invalid escape sequence");
                }
                enforce(last <= end,"inverted range");
                set.add(Interval(last,end)); 
                state = State.Start;
                break;
            }
            enforce(next(), "unexpected end of charset");
        }
        return tuple(set, op);
    }
    /**
        Parse and store IR for charset
    */
    void parseCharset()
    {
        Stack!(Charset, CTFE) vstack;
        Stack!(Operator, CTFE) opstack;
        //
        static bool apply(Operator op, ref Stack!(Charset,CTFE) stack)
        {
            switch(op)
            {
            case Operator.Negate:
                stack.top.negate;
                break;
            case Operator.Union:
                auto s = stack.pop();//2nd operand
                enforce(!stack.empty, "no operand for '||'");
                stack.top.add(s);
                break;
            case Operator.Difference:
                auto s = stack.pop();//2nd operand
                enforce(!stack.empty, "no operand for '--'");
                stack.top.sub(s);
                break;
            case Operator.SymDifference:
                auto s = stack.pop();//2nd operand
                enforce(!stack.empty, "no operand for '~~'");
                stack.top.symmetricSub(s);
                break;
            case Operator.Intersection:
                auto s = stack.pop();//2nd operand
                enforce(!stack.empty, "no operand for '&&'");
                stack.top.intersect(s);
                break;
            default:
                return false;
            }
            return true;
        }
        static bool unrollWhile(alias cond)(ref Stack!(Charset, CTFE) vstack, ref Stack!(Operator, CTFE) opstack)
        {
            while(cond(opstack.top))
            {
                debug(fred_charset)
                {
                    writeln(opstack.stack.data);
                    //writeln(map!"a.intervals"(vstack.stack.data));
                }
                if(!apply(opstack.pop(),vstack))
                    return false;//syntax error
                if(opstack.empty)
                    return false;
            }
            return true;
        }

        L_CharsetLoop:
        do
        {
            switch(current)
            {
            case '[':
                opstack.push(Operator.Open);
                enforce(next(), "unexpected end of charset");
                if(current == '^')
                {
                    opstack.push(Operator.Negate);
                    enforce(next(), "unexpected end of charset");
                }
                //[] is prohibited
                enforce(current != ']', "wrong charset");
                goto default;
            case ']':
                enforce(unrollWhile!(unaryFun!"a != a.Open")(vstack, opstack),
                        "charset syntax error");
                enforce(!opstack.empty, "unmatched ']'");
                opstack.pop();
                next();
              /*  writeln("After ] ", current, pat);
                writeln(opstack.stack.data);
                writeln(map!"a.intervals"(vstack.stack.data));
                writeln("---");*/
                if(opstack.empty)
                    break L_CharsetLoop;
                auto pair  = parseCharTerm();
                if(!pair[0].empty)//not only operator e.g. -- or ~~
                {
                    vstack.top.add(pair[0]);//apply union
                }
                if(pair[1] != Operator.None)
                {
                    if(opstack.top == Operator.Union)
                        unrollWhile!(unaryFun!"a == a.Union")(vstack, opstack);
                    opstack.push(pair[1]);
                }
                break;
            //
            default://yet another pair of term(op)?
                auto pair = parseCharTerm();
                if(pair[1] != Operator.None)
                {
                    if(opstack.top == Operator.Union)
                        unrollWhile!(unaryFun!"a == a.Union")(vstack, opstack);
                    opstack.push(pair[1]);
                }
                vstack.push(pair[0]);
            }

        }while(!empty || !opstack.empty);
        while(!opstack.empty)
            apply(opstack.pop(),vstack);
        //CTFE workaround
        assert(vstack.stack.data.length == 1);
        charsetToIr(vstack.top);
    }
    //try to generate optimal IR code for this charset
    void charsetToIr(in Charset set)
    {
        uint chars = set.chars();
        if(chars < Bytecode.MaxSequence)
        {
            switch(chars)
            {
                case 1:
                    put(Bytecode(IR.Char, set.ivals[0]));
                    break;
                case 0:
                    break;
                default:
                    foreach(ch; set[])
                        put(Bytecode(IR.OrChar, ch, chars));
            }
        }
        else
        {
            //TODO: better heuristic
            version(fred_ct)
            {//fight off memory usage
                put(Bytecode(IR.Charset, charsets.length));
                charsets ~= set;
            }
            else
            {
                if(set.ivals.length > 4)
                {//also CTFE memory overflow workaround
                    auto t  = getTrie(set);
                    put(Bytecode(IR.Trie, tries.length));
                    tries ~= t;
                }
                else
                {
                    put(Bytecode(IR.Charset, charsets.length));
                    charsets ~= set;
                }
            }
        }
    }
    ///parse and generate IR for escape stand alone escape sequence
    void parseEscape()
    {

        switch(current)
        {
        case 'f':   next(); put(Bytecode(IR.Char, '\f')); break;
        case 'n':   next(); put(Bytecode(IR.Char, '\n')); break;
        case 'r':   next(); put(Bytecode(IR.Char, '\r')); break;
        case 't':   next(); put(Bytecode(IR.Char, '\t')); break;
        case 'v':   next(); put(Bytecode(IR.Char, '\v')); break;

        case 'd':   
            next(); 
            put(Bytecode(IR.Charset, charsets.length)); 
            charsets ~= unicodeNd;
            break;
        case 'D':   
            next(); 
            put(Bytecode(IR.Charset, charsets.length)); 
            charsets ~= unicodeNd.dup.negate;//TODO: non-allocating  method
            break;
        case 'b':   next(); put(Bytecode(IR.Wordboundary, 0)); break;
        case 'B':   next(); put(Bytecode(IR.Notwordboundary, 0)); break;
        case 's':
            next();  
            charsetToIr(unicodeWhite_Space);
            break;
        case 'S':
            next();
            charsetToIr(unicodeWhite_Space.dup.negate);//TODO: non-allocating  method
            break;
        case 'w':
            next();
            put(Bytecode(IR.Trie, tries.length)); 
            tries ~= wordTrie;
            break;
        case 'W':   
            next(); 
            Trie t = wordTrie.negated;
            put(Bytecode(IR.Trie, tries.length)); 
            tries ~= t;
            break;
        case 'p': case 'P':
            auto charset = parseUnicodePropertySpec(current == 'P');
            charsetToIr(charset);
            break;
        case 'x':
            uint code = parseUniHex(pat, 2);
            next();
            put(Bytecode(IR.Char,code));
            break;
        case 'u': case 'U':
            uint code = parseUniHex(pat, current == 'u' ? 4 : 8);
            next();
            put(Bytecode(IR.Char, code));
            break;
        case 'c': //control codes
            Bytecode code = Bytecode(IR.Char, parseControlCode());
            next();
            put(code);
            break;
        case '0':
            next();
            put(Bytecode(IR.Char, 0));//NUL character
            break;
        case '1': .. case '9': //TODO: use $ instead of \ for backreference
            uint nref = cast(uint)current - '0';
            enforce(nref <  ngroup, "Backref to unseen group");
            //perl's disambiguation rule i.e.
            //get next digit only if there is such group number
            while(nref < ngroup && next() && ascii.isDigit(current))
            {
                nref = nref * 10 + current - '0';
            }
            if(nref >= ngroup)
                nref /= 10;
            put(Bytecode(IR.Backref, nref));
            break;
        default:
            auto op = Bytecode(IR.Char, current);
            next();
            put(op);
        }
    }
	/// parse and return a Charset for \p{...Property...} and \P{...Property..},
	// \ - assumed to be processed, p - is current
	immutable(Charset) parseUnicodePropertySpec(bool negated)
	{
        alias comparePropertyName ucmp;
        enum MAX_PROPERTY = 128;
		enforce(next() && current == '{', "{ expected ");
        char[MAX_PROPERTY] result;
        uint k=0;
        while(k<MAX_PROPERTY && next() && current !='}' && current !=':')
            if(current != '-' && current != ' ' && current != '_')
                result[k++] = cast(char)ascii.toLower(current);
        enforce(k != MAX_PROPERTY, "invalid property name");
		auto s = getUnicodeSet(result[0..k], negated);
		enforce(!s.empty, "unrecognized unicode property spec");
		enforce(current == '}', "} expected ");
		next();
		return cast(immutable Charset)(s);
	}
    //
    void error(string msg)
    {
        auto app = appender!string;
        ir = null;
        formattedWrite(app,"%s\nPattern with error: `%s <--HERE-- %s`",
                       msg, origin[0..$-pat.length], pat);
        throw new RegexException(app.data);
    }
    ///packages parsing results into a Program object
    @property Program program()
    {
        return Program(this);
    }
}

///Object that holds all persistent data about compiled regex
struct Program
{
    Bytecode[] ir;      // compiled bytecode of pattern
    NamedGroup[] dict;  //maps name -> user group number
    uint ngroup;        //number of internal groups
    uint maxCounterDepth; //max depth of nested {n,m} repetitions
    uint hotspotTableSize; // number of entries in merge table
    uint flags;         //global regex flags
    const(Charset)[] charsets; //
    const(Trie)[]  tries; //
    /++
        lightweight post process step - no GC allocations (TODO!),
        only essentials
    +/
    void lightPostprocess()
    {
        uint[] counterRange = new uint[maxCounterDepth+1];
        uint hotspotIndex = 0;
        uint top = 0;
        counterRange[0] = 1;
        //CTFE workaround for .length
        for(size_t i=0; i<ir.length; i+=lengthOfIR(ir[i].code))
        {
            if(ir[i].code == IR.RepeatStart || ir[i].code == IR.RepeatQStart)
            {
                uint repEnd = i + ir[i].data + IRL!(IR.RepeatStart);
                assert(ir[repEnd].code == ir[i].paired.code);
                uint max = ir[repEnd + 3].raw;
                ir[repEnd+1].raw = counterRange[top];
                ir[repEnd+2].raw *= counterRange[top];
                ir[repEnd+3].raw *= counterRange[top];
                counterRange[top+1] = (max+1) * counterRange[top];
                top++;
            }
            else if(ir[i].code == IR.RepeatEnd || ir[i].code == IR.RepeatQEnd)
            {
                top--;
            }
            if(ir[i].hotspot)
            {
                assert(i + 1 < ir.length, "unexpected end of IR while looking for hotspot");
                ir[i+1] = Bytecode.fromRaw(hotspotIndex);
                hotspotIndex += counterRange[top];
            }
        }
        hotspotTableSize = hotspotIndex;
    }
    /// IR code validator - proper nesting, illegal instructions, etc.
    void validate()
    {
        for(size_t pc=0; pc<ir.length; pc+=ir[pc].length)
        {
            if(ir[pc].isStart || ir[pc].isEnd)
            {
                uint dest =  ir[pc].indexOfPair(pc);
                assert(dest < ir.length, text("Wrong length in opcode at pc=",pc));
                assert(ir[dest].paired ==  ir[pc],
                        text("Wrong pairing of opcodes at pc=", pc, "and pc=", dest));
            }
            else if(ir[pc].isAtom)
            {

            }
            else
               assert(0, text("Unknown type of instruction at pc=", pc));
        }
    }
    /// print out disassembly a program's IR
    void print() const
    {
        writefln("PC\tINST\n");
        prettyPrint(delegate void(const(char)[] s){ write(s); },ir);
        writefln("\n");
        for(size_t i=0; i<ir.length; i+=ir[i].length)
        {
            writefln("%d\t%s ", i, disassemble(ir, i, dict));
        }
        writeln("Total merge table size: ", hotspotTableSize);
        writeln("Max counter nesting depth: ", maxCounterDepth);
    }
	///
	uint lookupNamedGroup(String)(String name) 
	{
		//auto fnd = assumeSorted(map!"a.name"(dict)).lowerBound(name).length;
        uint fnd;
        for(fnd = 0; fnd<dict.length; fnd++)
            if(equal(dict[fnd].name,name))
                break;
        if(fnd == dict.length)
               throw new Exception("out of range");
		return dict[fnd].group;
	}
	///
    this(S,bool x)(Parser!(S,x) p)
    {
        if(__ctfe)//CTFE something funky going on with array
            ir = p.ir.dup;
        else
            ir = p.ir;
        dict = p.dict;
        ngroup = p.ngroup;
        maxCounterDepth = p.counterDepth;
        flags = p.re_flags;
        charsets = p.charsets;
        tries = p.tries;
        lightPostprocess();
        debug(fred_parser)
        {
            print();
            validate();
        }
    }
}

///Test if bytecode starting at pc in program 're' can match given codepoint
///Returns: length of matched atomsif test is positive, 0 - can't tell, -1 if doesn't match
int quickTestFwd(uint pc, dchar front, Program re)
{
    static assert(IRL!(IR.OrChar) == 1);//used in code processing IR.OrChar 
    if(pc >= re.ir.length)
        return pc;
    switch(re.ir[pc].code)
    {
    case IR.OrChar:
        uint len = re.ir[pc].sequence;
        uint end = pc + len;
        if(re.ir[pc].data != front && re.ir[pc+1].data != front)
        {
            for(pc = pc+2; pc<end; pc++)
                if(re.ir[pc].data == front)
                    break;
            if(pc == end)
                return -1;
        }
        return cast(int)len;
    case IR.Char:
        if(front == re.ir[pc].data)
            return IRL!(IR.Char);
        else
            return -1;
    case IR.Any:
        return IRL!(IR.Any);
    case IR.Charset:
        if(re.charsets[re.ir[pc].data][front])
            return IRL!(IR.Charset);
        else
            return -1;
    case IR.Trie:
        if(re.tries[re.ir[pc].data][front])
            return IRL!(IR.Trie);
        else
            return -1;        
    default:
        return 0;
    }
}

///std.regex-like Regex object wrapper, provided for backwards compatibility
/*struct Regex(Char)
    if(is(Char : char) || is(Char : wchar) || is(Char : dchar))
{
    Program storage;
    this(Program rs){ storage = rs; }
    alias storage this;

}*/
template Regex(Char)
    if(is(Char : char) || is(Char : wchar) || is(Char : dchar))
{
    alias Program Regex;
}

/// Simple UTF-string stream abstraction (w/o normalization and such)
struct Input(Char)
    if(is(Char :dchar))
{
    alias const(Char)[] String;
    String _origin;
    size_t _index;
    /// constructs Input object out of plain string
    this(String input, size_t idx=0)
    {
        _origin = input;
        _index = idx;
    }
    /// codepoint at current stream position
    bool nextChar(ref dchar res,ref size_t pos)
    {
        if(_index == _origin.length)
            return false;
        pos = _index;
        res = std.utf.decode(_origin, _index);
        return true;
    }
    ///index of at End position
    @property size_t lastIndex(){   return _origin.length; }
    
    ///support for backtracker engine, might not be present
    void reset(size_t index){   _index = index;  }
    
    String opSlice(size_t start, size_t end){   return _origin[start..end]; }
    
    struct BackLooper
    {
        String _origin;
        size_t _index;
        this(Input input)
        {
            _origin = input._origin;
            _index = input._index;
        }
        bool nextChar(ref dchar res,ref size_t pos)
        {
            if(_index == 0)
                return false;
            _index -= std.utf.strideBack(_origin, _index);
            if(_index == 0)
                return false;
            pos = _index;
            res = _origin[0.._index].back;
            return true;
        }
        @property auto loopBack(){   return Input(_origin, _index); }
        
        ///support for backtracker engine, might not be present
        void reset(size_t index){   _index = index+std.utf.stride(_origin, index);  }
        
        String opSlice(size_t start, size_t end){   return _origin[end..start]; }
        ///index of at End position
        @property size_t lastIndex(){   return 0; }
    }
    @property auto loopBack(){   return BackLooper(this); }
}


/++
    BacktrackingMatcher implements backtracking scheme of matching
    regular expressions.
    low level construct, doesn't 'own' any memory
+/
struct BacktrackingMatcher(Char, Stream=Input!Char)
    if(is(Char : dchar))
{
    struct State
    {//top bit in pc is set if saved along with matches
        size_t index;
        uint pc, counter, infiniteNesting;
    }
    alias const(Char)[] String;
    Program re;           //regex program
    enum initialStack = 2^^12;
    enum dirtyBit = 1<<31;
    //Stream state
    Stream s;
    size_t index;
    dchar front;
    bool exhausted;
    bool seenCr;
    //backtracking machine state
    uint pc, counter;
    uint lastState = 0;          //top of state stack
    uint lastGroup = 0;       //ditto for matches
    bool matchesDirty; //flag, true if there are unsaved changes to matches
    size_t[] trackers;
    uint infiniteNesting;
    State[] states;
    Group[] groupStack;//array list
    Group[] matches;
    
    ///
    @property bool atStart(){ return index == 0; }
    ///
    @property bool atEnd(){ return index == s.lastIndex; }
    ///
    void next()
    {    
        seenCr = front == '\r';
        if(!s.nextChar(front, index))
            index = s.lastIndex;
    }
    ///
    this(Program program, Stream stream)
    {
        re = program;
        s = stream;
        exhausted = false;
        next();
        trackers = new size_t[re.ngroup+1];
        states = new State[initialStack];
        groupStack = new Group[initialStack];
    }
    ///lookup next match, fills matches with indices into input
    bool match(Group matches[])
    {
        debug(fred_matching)
        {
            writeln("------------------------------------------");
        }
        if(exhausted) //all matches collected
            return false;
        this.matches = matches[1..$];
        version(none)
        {
            RegionAllocator alloc = newRegionAllocator();
            trackers = alloc.uninitializedArray!(size_t[])(re.ngroup+1);  //TODO: it's smaller, make parser count nested infinite loops
            states = alloc.uninitializedArray!(State[])(initialStack);
            groupStack = alloc.uninitializedArray!(Group[])(initialStack);
        }
        for(;;)
        {
            
            size_t start = index;
            if(matchImpl())
            {//stream is updated here
                matches[0].begin = start;
                matches[0].end = index;
                if(!(re.flags & RegexOption.global) || atEnd)
                    exhausted = true;
                if(start == index)//empty match advances input
                    next();
                return true;
            }
            else
                next();
            if(atEnd)
                break;
            next();
        }
        exhausted = true;
        return false;
    }
    /++
        match subexpression against input, using provided malloc'ed array as stack,
        results are stored in matches
    +/
    bool matchImpl()
    {
        pc = 0;
        counter = 0;
        lastState = 0;
        infiniteNesting = -1;// intentional
        matchesDirty = false;
        //setup first frame for incremental match storage
        assert(groupStack.length >= matches.length);
        groupStack[0 .. matches.length] = Group.init;
        lastGroup = matches.length;        
        auto start = index;
        debug(fred_matching) writeln("Try match starting at ",s[index..s.lastIndex]);        
        while(pc<re.ir.length)
        {
            debug(fred_matching) writefln("PC: %s\tCNT: %s\t%s \tfront: %s src: %s", pc, counter, disassemble(re.ir, pc, re.dict), front, s._index);
            switch(re.ir[pc].code)
            {
            case IR.OrChar://assumes IRL!(OrChar) == 1
                if(atEnd)
                    goto L_backtrack;
                uint len = re.ir[pc].sequence;
                uint end = pc + len;
                if(re.ir[pc].data != front && re.ir[pc+1].data != front)
                {
                    for(pc = pc+2; pc<end; pc++)
                        if(re.ir[pc].data == front)
                            break;
                    if(pc == end)
                        goto L_backtrack;
                }
                pc = end;
                next();
                break;
            case IR.Char:
                if(atEnd || front != re.ir[pc].data)
                    goto L_backtrack;
                pc += IRL!(IR.Char);
                next();
            break;
            case IR.Any:
                if(atEnd)
                    goto L_backtrack;
                pc += IRL!(IR.Any);
                next();
                break;
            case IR.Charset:
                if(atEnd || !re.charsets[re.ir[pc].data][front])
                    goto L_backtrack;
                next();
                pc += IRL!(IR.Charset);
                break;
            case IR.Trie:
                if(atEnd || !re.tries[re.ir[pc].data][front])
                    goto L_backtrack;
                next();
                pc += IRL!(IR.Trie);
                break;
            case IR.Wordboundary:
                dchar back;
                size_t bi;
                //at start & end of input
                if(atStart && wordTrie[front])
                {
                    pc += IRL!(IR.Wordboundary);
                    break;
                }
                else if(atEnd && s.loopBack.nextChar(back, bi)
                        && wordTrie[back])
                {
                    pc += IRL!(IR.Wordboundary);
                    break;
                }
                else if(s.loopBack.nextChar(back, index))
                {
                    bool af = wordTrie[front];
                    bool ab = wordTrie[back];
                    if(af ^ ab)
                    {
                        pc += IRL!(IR.Wordboundary);
                        break;
                    }
                }
                goto L_backtrack;
                break;
            case IR.Notwordboundary:
                dchar back;
                size_t bi;
                //at start & end of input
                if(atStart && !wordTrie[front])
                    goto L_backtrack;
                else if(atEnd && s.loopBack.nextChar(back, bi)
                        && !isUniAlpha(back))
                    goto L_backtrack;
                else if(s.loopBack.nextChar(back, index))
                {
                    bool af = wordTrie[front];
                    bool ab = wordTrie[back];
                    if(af ^ ab)
                        goto L_backtrack;
                }
                pc += IRL!(IR.Wordboundary);
                break;
            case IR.Bol:
                dchar back;
                size_t bi;
                //TODO: multiline & attributes, unicode line terminators
                if(atStart)
                    pc += IRL!(IR.Bol);
                else if(s.loopBack.nextChar(back,bi) && back == '\n') 
                    pc += IRL!(IR.Bol);
                else
                    goto L_backtrack;
                break;
            case IR.Eol:
                debug(fred_matching) writefln("EOL (seen CR: %s, front 0x%x) %s", seenCr, front, s[index..s.lastIndex]);
                //no matching inside \r\n
                if(atEnd || ((front == '\n') ^ seenCr) || front == LS 
                    || front == PS || front == NEL)
                {
                    pc += IRL!(IR.Eol);
                }
                else
                    goto L_backtrack;
                break;
            case IR.InfiniteStart, IR.InfiniteQStart:
                trackers[infiniteNesting+1] = index;
                pc += re.ir[pc].data + IRL!(IR.InfiniteStart);
                //now pc is at end IR.Infininite(Q)End
                uint len = re.ir[pc].data;
                int test;
                if(re.ir[pc].code == IR.InfiniteEnd)
                {
                    test = quickTestFwd(pc+IRL!(IR.InfiniteEnd), front, re);
                    if(test >= 0)//TODO: can do better if > 0 
                        pushState(pc+IRL!(IR.InfiniteEnd), counter);
                    infiniteNesting++;
                    pc -= len;
                }
                else
                {
                    test = quickTestFwd(pc - len, front, re);
                    if(test >= 0)//TODO: can do better if > 0 
                    {
                        infiniteNesting++;
                        pushState(pc - len, counter);
                        infiniteNesting--;
                    }
                    pc += IRL!(IR.InfiniteEnd);
                }
                break;
            case IR.RepeatStart, IR.RepeatQStart:
                pc += re.ir[pc].data + IRL!(IR.RepeatStart);
                break;
            case IR.RepeatEnd:
            case IR.RepeatQEnd:
                // len, step, min, max
                uint len = re.ir[pc].data;
                uint step =  re.ir[pc+1].raw;
                uint min = re.ir[pc+2].raw;
                uint max = re.ir[pc+3].raw;
                //debug(fred_matching) writefln("repeat pc=%u, counter=%u",pc,counter);

                if(counter < min)
                {
                    counter += step;
                    pc -= len;
                }
                else if(counter < max)
                {
                    if(re.ir[pc].code == IR.RepeatEnd)
                    {
                        pushState(pc + IRL!(IR.RepeatEnd), counter%step);
                        counter += step;
                        pc -= len;
                    }
                    else
                    {
                        pushState(pc - len, counter + step);
                        counter = counter%step;
                        pc += IRL!(IR.RepeatEnd);
                    }
                }
                else
                {
                    counter = counter%step;
                    pc += IRL!(IR.RepeatEnd);
                }
                break;
            case IR.InfiniteEnd:
            case IR.InfiniteQEnd:
                uint len = re.ir[pc].data;
                debug(fred_matching) writeln("Infinited nesting:", infiniteNesting);
                assert(infiniteNesting < trackers.length);

                if(trackers[infiniteNesting] == index)
                {//source not consumed
                    pc += IRL!(IR.InfiniteEnd);
                    infiniteNesting--;
                    break;
                }
                else
                    trackers[infiniteNesting] = index;
                int test;
                if(re.ir[pc].code == IR.InfiniteEnd)
                {
                    test = quickTestFwd(pc+IRL!(IR.InfiniteEnd), front, re);
                    if(test >= 0)
                    {
                        infiniteNesting--;
                        pushState(pc + IRL!(IR.InfiniteEnd), counter);
                        infiniteNesting++;
                    }
                    pc -= len;
                }
                else
                {
                    test = quickTestFwd(pc-len, front, re);
                    if(test >= 0)
                        pushState(pc-len, counter);
                    pc += IRL!(IR.InfiniteEnd);
                    infiniteNesting--;
                }
                break;
            case IR.OrEnd:
                pc += IRL!(IR.OrEnd);
                break;
            case IR.OrStart:
                pc += IRL!(IR.OrStart);
                goto case;
            case IR.Option:
                uint len = re.ir[pc].data;
                if(re.ir[pc+len].code == IR.GotoEndOr)//not a last one
                {
                    pushState(pc + len + IRL!(IR.Option), counter); //remember 2nd branch
                }
                pc += IRL!(IR.Option);
                break;
            case IR.GotoEndOr:
                pc = pc + re.ir[pc].data + IRL!(IR.GotoEndOr);
                break;
            case IR.GroupStart:
                uint n = re.ir[pc].data;
                matches[n-1].begin = index;//the first is sliced out
                matchesDirty = true;
                debug(fred_matching)  writefln("IR group #%u starts at %u", n, index);
                pc += IRL!(IR.GroupStart);
                break;
            case IR.GroupEnd:
                uint n = re.ir[pc].data;
                matches[n-1].end = index;//the first is sliced out
                matchesDirty = true;
                debug(fred_matching) writefln("IR group #%u ends at %u", n, index);
                pc += IRL!(IR.GroupEnd);
                break;
            /*case IR.LookaheadStart:
            case IR.NeglookaheadStart:
                uint len = re.ir[pc].data;
                auto save = index;
                auto ch = front;
                uint matched = matchImpl(re.ir[pc+1 .. pc+1+len], matches);
                s.reset(save);
                front = ch;
                if(matched ^ (re.ir[pc].code == IR.LookaheadStart))
                    goto L_backtrack;
                pc += IRL!(IR.LookaheadStart) + IRL!(IR.LookaheadEnd) + len;
                break;*/
            case IR.LookbehindStart:
            case IR.NeglookbehindStart:
                uint len = re.ir[pc].data;
                auto prog = re;
                prog.ir = re.ir[pc .. pc+IRL!(IR.LookbehindStart)+len];
                auto backMatcher = BacktrackingMatcher!(Char, typeof(s.loopBack))(prog, s.loopBack);
                backMatcher.matches = matches;
                bool match = backMatcher.matchBackImpl() ^ (re.ir[pc].code == IR.NeglookbehindStart);
                if(!match)
                    goto L_backtrack;
                else
                {
                    pc += IRL!(IR.LookbehindStart)+len+IRL!(IR.LookbehindEnd);
                    matchesDirty = true;
                }
                break;
            case IR.Backref:
                uint n = re.ir[pc].data;
                auto referenced = s[matches[n-1].begin .. matches[n-1].end];
                while(!atEnd && !referenced.empty && front == referenced.front)
                {
                    next();
                    referenced.popFront();
                }
                if(referenced.empty)
                    pc++;
                else
                    goto L_backtrack;
                break;
                case IR.Nop:
                pc += IRL!(IR.Nop);
                break;
            case IR.LookaheadEnd:
            case IR.NeglookaheadEnd:
                return true;
            default:
                assert(0);
            L_backtrack:
                if(!popState())
                {
                    s.reset(start);
                    return false;
                }
            }
        }
        return true;
    }
    /*
        helper function saves engine state
    */
    void pushState(uint pc, uint counter)
    {
        if(matchesDirty)
        {
            if(lastGroup >= groupStack.length)
                groupStack.length *= 2;
            lastGroup += matches.length;
            groupStack[lastGroup-matches.length .. lastGroup] = matches[];
            debug(fred_matching)
            {
                writeln("Saved matches");
                foreach(i, m; matches)
                    writefln("Sub(%d) : %s..%s", i, m.begin, m.end);
            }
        }
        if(lastState >= states.length)
            states.length *= 2;
        states[lastState++] = State(index, matchesDirty ? pc | dirtyBit : pc , counter, infiniteNesting);
        matchesDirty = false;
        debug(fred_matching)
            writefln("Saved front: %s src: %s", front, s[index..s.lastIndex]);
    }
    //helper function restores engine state        
    bool popState()
    {
        if(!lastState)
            return false;
        auto state = states[--lastState];
        index = state.index;
        pc = state.pc;
        counter = state.counter;
        infiniteNesting = state.infiniteNesting;
        if(pc & dirtyBit)
        {
            pc ^= dirtyBit;
            matches[] = groupStack[lastGroup-matches.length .. lastGroup];
            lastGroup -= matches.length;
            matchesDirty = false;
            debug(fred_matching)
            {
                writefln("Restored matches", front, s[index .. s.lastIndex]);
                foreach(i, m; matches)
                    writefln("Sub(%d) : %s..%s", i, m.begin, m.end);
            }
        }
        else if(matchesDirty)// since last save there were changes not saved onces
        {
            matches[] = groupStack[lastGroup-matches.length .. lastGroup];//take from previous save point
            matchesDirty = false;
        }
        s.reset(index);
        next();
        debug(fred_matching)
            writefln("Backtracked front: %s src: %s", front, s[index..s.lastIndex]);
        return true;
    }
    /++
        Match subexpression against input, executing re.ir backwards, using provided malloc'ed array as stack.
        Results are stored in matches
    ++/
    bool matchBackImpl()
    {
        pc = re.ir.length-1;
        counter = 0;
        lastState = 0;
        infiniteNesting = -1;// intentional
        matchesDirty = false;
        version(none)
        {
            RegionAllocator alloc = newRegionAllocator();
            trackers = alloc.uninitializedArray!(size_t[])(re.ngroup+1);  //TODO: it's smaller, make parser count nested infinite loops
            states = alloc.uninitializedArray!(State[])(initialStack);
            groupStack = alloc.uninitializedArray!(Group[])(initialStack);
        }
        //setup first frame for incremental match storage
        assert(groupStack.length >= matches.length);
        groupStack[0 .. matches.length] = Group.init;
        lastGroup += matches.length;
        auto start = index;
        debug(fred_matching) writeln("Try matchBack at ",retro(s[index..s.lastIndex]));        
        for(;;)
        {
            debug(fred_matching) writefln("PC: %s\tCNT: %s\t%s \tfront: %s src: %s", pc, counter, disassemble(re.ir, pc, re.dict), front, retro(s[index..s.lastIndex]));
            switch(re.ir[pc].code)
            {
            case IR.OrChar://assumes IRL!(OrChar) == 1
                if(atEnd)
                    goto L_backtrack;
                uint len = re.ir[pc].sequence;
                uint end = pc - len;
                if(re.ir[pc].data != front && re.ir[pc-1].data != front)
                {
                    for(pc = pc-2; pc>end; pc--)
                        if(re.ir[pc].data == front)
                            break;
                    if(pc == end)
                        goto L_backtrack;
                }
                pc = end;
                next();
                break;
            case IR.Char:
                if(atEnd || front != re.ir[pc].data)
                   goto L_backtrack;
                pc--;
                next();
            break;
            case IR.Any:
                if(atEnd)
                    goto L_backtrack;
                pc--;
                next();
                break;
            case IR.Charset:
                if(atEnd || !re.charsets[re.ir[pc].data][front])
                    goto L_backtrack;
                next();
                pc--;
                break;
            case IR.Trie:
                if(atEnd || !re.tries[re.ir[pc].data][front])
                    goto L_backtrack;
                next();
                pc--;
                break;
            case IR.Wordboundary:
                dchar back;
                size_t bi;
                //at start & end of input
                if(atStart && wordTrie[front])
                {
                    pc--;
                    break;
                }
                else if(atEnd && s.loopBack.nextChar(back, bi)
                        && wordTrie[back])
                {
                    pc--;
                    break;
                }
                else if(s.loopBack.nextChar(back, index))
                {
                    bool af = wordTrie[front];
                    bool ab = wordTrie[back];
                    if(af ^ ab)
                    {
                        pc--;
                        break;
                    }
                }
                goto L_backtrack;
                break;
            case IR.Notwordboundary:
                dchar back;
                size_t bi;
                //at start & end of input
                if(atStart && !wordTrie[front])
                    goto L_backtrack;
                else if(atEnd && s.loopBack.nextChar(back, bi)
                        && !wordTrie[back])
                    goto L_backtrack;
                else if(s.loopBack.nextChar(back, index))
                {
                    bool af = wordTrie[front];
                    bool ab = wordTrie[back];
                    if(af ^ ab)
                       goto L_backtrack;
                }
                pc--;
                break;
            case IR.Bol:
                dchar back;
                size_t bi;
                //TODO: multiline & attributes, unicode line terminators
                if(atStart)
                    pc--;
                else if(s.loopBack.nextChar(back,bi) && back == '\n') 
                    pc--;
                else
                    goto L_backtrack;
                break;
            case IR.Eol:
                debug(fred_matching) writefln("EOL (seen CR: %s, front 0x%x) %s", seenCr, front, s[index..s.lastIndex]);
                //no matching inside \r\n
                if(((front == '\n') ^ seenCr) || front == LS 
                    || front == PS || front == NEL)
                {
                    pc -= IRL!(IR.Eol);
                }
                else
                    goto L_backtrack;
                break;
            case IR.InfiniteStart, IR.InfiniteQStart:
                uint len = re.ir[pc].data;
                assert(infiniteNesting < trackers.length);
                if(trackers[infiniteNesting] == index)
                {//source not consumed
                    pc--; //out of loop
                    infiniteNesting--;
                    break;
                }
                else
                    trackers[infiniteNesting] = index;
                if(re.ir[pc].code == IR.InfiniteStart)//greedy
                {
                    infiniteNesting--;
                    pushState(pc-1, counter);//out of loop
                    infiniteNesting++;
                    pc += len;
                }
                else
                {
                    pushState(pc+len, counter);
                    pc--;
                    infiniteNesting--;
                }
                break;
            case IR.InfiniteEnd:
            case IR.InfiniteQEnd://now it's a start
                uint len = re.ir[pc].data;
                trackers[infiniteNesting+1] = index;
                pc -= len+IRL!(IR.InfiniteStart);
                assert(re.ir[pc].code == IR.InfiniteStart || re.ir[pc].code == IR.InfiniteQStart);
                debug(fred_matching) writeln("(backmatch) Infinite nesting:", infiniteNesting);
                if(re.ir[pc].code == IR.InfiniteStart)//greedy
                {
                    pushState(pc-1, counter);
                    infiniteNesting++;
                    pc += len;
                }
                else
                {
                    infiniteNesting++;
                    pushState(pc + len, counter);
                    infiniteNesting--;
                    pc--;
                }
                break;
            case IR.RepeatStart, IR.RepeatQStart:
                uint len = re.ir[pc].data;
                uint tail = pc + len + 1;
                uint step =  re.ir[tail+1].raw;
                uint min = re.ir[tail+2].raw;
                uint max = re.ir[tail+3].raw;
                if(counter < min)
                {
                    counter += step;
                    pc += len;
                }
                else if(counter < max)
                {
                    if(re.ir[pc].code == IR.RepeatStart)//greedy
                    {
                        pushState(pc-1, counter%step);
                        counter += step;
                        pc += len;
                    }
                    else
                    {
                        pushState(pc + len, counter + step);
                        counter = counter%step;
                        pc--;
                    }
                }
                else
                {
                    counter = counter%step;
                    pc--;
                }
                break;
            case IR.RepeatEnd:
            case IR.RepeatQEnd:
                pc -= re.ir[pc].data+IRL!(IR.RepeatStart);
                assert(re.ir[pc].code == IR.RepeatStart || re.ir[pc].code == IR.RepeatQStart);
                goto case IR.RepeatStart;
            case IR.OrEnd:
                uint len = re.ir[pc].data;
                pc -= len;
                assert(re.ir[pc].code == IR.Option);
                len = re.ir[pc].data;
                auto pc_save = pc+len-1;
                pc = pc + len + IRL!(IR.Option);
                while(re.ir[pc].code == IR.Option)
                {
                    pushState(pc-IRL!(IR.GotoEndOr)-1, counter);
                    len = re.ir[pc].data;
                    pc += len + IRL!(IR.Option);
                }
                assert(re.ir[pc].code == IR.OrEnd);
                pc--;
                if(pc != pc_save)
                {
                    pushState(pc, counter);
                    pc = pc_save;
                }
                break;
            case IR.OrStart:
                assert(0);
            case IR.Option:
                assert(re.ir[pc].code == IR.Option);
                pc += re.ir[pc].data + IRL!(IR.Option);
                if(re.ir[pc].code == IR.Option)
                {
                    pc--;//hackish, assumes size of IR.Option == 1
                    if(re.ir[pc].code == IR.GotoEndOr)
                    {
                        pc += re.ir[pc].data + IRL!(IR.GotoEndOr);
                    }
                    
                }
                assert(re.ir[pc].code == IR.OrEnd);
                pc -= re.ir[pc].data + IRL!(IR.OrStart)+1;
                break;
            case IR.GotoEndOr:
                assert(0);
            case IR.GroupStart:
                uint n = re.ir[pc].data;
                matches[n-1].begin = index;
                matchesDirty = true;
                debug(fred_matching)  writefln("IR group #%u starts at %u", n, index);
                pc --;
                break;
            case IR.GroupEnd:  
                uint n = re.ir[pc].data;
                matches[n-1].end = index;
                matchesDirty = true;
                debug(fred_matching) writefln("IR group #%u ends at %u", n, index);
                pc --;
                break;
            case IR.LookaheadStart:
            case IR.NeglookaheadStart:
            case IR.LookaheadEnd:
            case IR.NeglookaheadEnd:
            case IR.LookbehindEnd:
            case IR.NeglookbehindEnd:
                assert(0, "No lookaround in look back");
            case IR.Backref:
                uint n = re.ir[pc].data;
                auto referenced = s[matches[n].begin .. matches[n].end];
                while(!atEnd && !referenced.empty && front == referenced.front)
                {
                    next();
                    referenced.popFront();
                }
                if(referenced.empty)
                    pc--;
                else
                    goto L_backtrack;
                break;
             case IR.Nop:
                pc --;
                break;
            case IR.LookbehindStart:
            case IR.NeglookbehindStart:
                return true;
            default:
                assert(re.ir[pc].code < 0x80);
                pc --; //data 
                break;
            L_backtrack:
                if(!popState())
                {
                    s.reset(start);
                    return false;
                }
            }
        }
        return true;
    }
}

///State of VM thread
struct Thread
{
    Thread* next;    //intrusive linked list
    uint pc;
    uint counter;    // loop counter
    uint uopCounter; // counts micro operations inside one macro instruction (e.g. BackRef)
    Group[1] matches;
}
///head-tail singly-linked list
struct ThreadList
{
    Thread* tip=null, toe=null;
    /// add new thread to the start of list
    void insertFront(Thread* t)
    {
        if(tip)
        {
            t.next = tip;
            tip = t;
        }
        else
        {
            t.next = null;
            tip = toe = t;
        }
    }
    //add new thread to the end of list
    void insertBack(Thread* t)
    {
        if(toe)
        {
            toe.next = t;
            toe = t;
        }
        else
            tip = toe = t;
        toe.next = null;
    }
    ///move head element out of list
    Thread* fetch()
    {
        auto t = tip;
        if(tip == toe)
            tip = toe = null;
        else
            tip = tip.next;
        return t;
    }
    ///non-destructive iteration of ThreadList
    struct ThreadRange
    {
        const(Thread)* ct;
        this(ThreadList tlist){ ct = tlist.tip; }
        @property bool empty(){ return ct == null; }
        @property const(Thread)* front(){ return ct; }
        @property popFront()
        {
            assert(ct);
            ct = ct.next;
        }
    }
    @property bool empty()
    {
        return tip == null;
    }
    ThreadRange opSlice()
    {
        return ThreadRange(this);
    }
}
    
/++
   Thomspon matcher does all matching in lockstep, never looking at the same char twice
+/
struct ThompsonMatcher(Char, Stream=Input!Char)
    if(is(Char : dchar))
{
    alias const(Char)[] String;
    enum threadAllocSize = 16;
    Thread* freelist;
    ThreadList clist, nlist;
    uint[] merge;
    Program re;           //regex program
    Stream s;
    dchar front;
    size_t index;
    size_t genCounter;    //merge trace counter, goes up on every dchar
    bool matched;
    bool seenCr;    //true if CR was processed    
    /// true if it's start of input
    @property bool atStart(){   return index == 0; }
    /// true if it's end of input
    @property bool atEnd(){  return index == s.lastIndex; }
    //
    bool next()
    {
        seenCr = front == '\r';
        if(!s.nextChar(front, index))
        {
            index =  s.lastIndex;
            return false;
        }
        return true;
    }
    ///
    this()(Program program, Stream stream)
    {
        s = stream;
        re = program;
        s = stream;
        if(re.hotspotTableSize)
        {
            merge = new uint[re.hotspotTableSize];
            reserve(re.hotspotTableSize+2);
        }
        genCounter = 0;
    }
    this(S)(ThompsonMatcher!(Char,S) matcher, Bytecode[] piece)
    {
        s = matcher.s.loopBack;
        re = matcher.re;
        re.ir = piece;
        merge = matcher.merge;
        genCounter = matcher.genCounter;
    }
    ///
    this(this)
    {
        merge = merge.dup;
        debug(fred_allocation) writeln("ThompsonVM postblit!");
        //free list is  efectively shared ATM
    }
    /++
        the usual match the input and fill matches
    +/
    bool match(Group[] matches)
    {
        debug(fred_matching)
        {
            writeln("------------------------------------------");
        }
        if(matched && !(re.flags & RegexOption.global))
           return false;
        if(!matched)
            next();
        else//char in question is  fetched in prev call to match
        {
            matched = false;
        }
        assert(clist == ThreadList.init);
        assert(nlist == ThreadList.init);
        if(!atEnd)// if no char 
            for(;;)
            {
                genCounter++;
                debug(fred_matching)
                {
                    writefln("Threaded matching threads at  %s", s[index..s.lastIndex]);
                    foreach(t; clist[])
                    {
                        assert(t);
                        writef("pc=%s ",t.pc);
                        write(t.matches);
                        writeln();
                    }
                }
                for(Thread* t = clist.fetch(); t; t = clist.fetch())
                {
                    eval!true(t, matches);
                }
                if(!matched)//if we already have match no need to push the engine
                    eval!true(createStart(index), matches);// new thread staring at this position
                else if(nlist.empty)
                {
                    debug(fred_matching) writeln("Stopped  matching before consuming full input");
                    break;//not a partial match for sure
                }
                clist = nlist;
                nlist = ThreadList.init;
                if(!next())
                    break;
            }
        genCounter++; //increment also on each end
        debug(fred_matching) writefln("Threaded matching threads at end");
        //try out all zero-width posibilities
        if(!matched)
            eval!false(createStart(index), matches);// new thread starting at end of input
        for(Thread* t = clist.fetch(); t; t = clist.fetch())
        {
            eval!false(t, matches);
        }
        //writeln("CLIST :", clist[]);
        //TODO: partial matching
        return matched;
    }
    /++
        handle succesful threads
    +/
    void finish(const(Thread)* t, Group[] matches, uint offset=0)
    {
        //debug(fred_matching) writeln(t.matches);
        matches.ptr[offset..re.ngroup] = t.matches.ptr[offset..re.ngroup];
        //end of the whole match happens after current symbol
        if(!offset)
            matches[0].end = index;
        debug(fred_matching) 
        {
            writefln("FOUND pc=%s prog_len=%s: %s..%s",
                    t.pc, re.ir.length,matches[0].begin, matches[0].end);
            foreach(v; matches)
                writefln("%d .. %d", v.begin, v.end);
        }
        matched = true;
    }
    /++
        match thread against codepoint, cutting trough all 0-width instructions
        and taking care of control flow, then add it to nlist
    +/
    void eval(bool withInput)(Thread* t, Group[] matches)
    {
        Bytecode[] prog = re.ir;
        ThreadList worklist;
        debug(fred_matching) writeln("Evaluating thread");
        do
        {
            debug(fred_matching)
            {
                writef("\tpc=%s [", t.pc);
                foreach(x; worklist[])
                    writef(" %s ", x.pc);
                writeln("]");
            }
            if(t.pc == prog.length)
            {
                finish(t, matches);
                recycle(t);
                //cut off low priority threads
                recycle(clist);
                recycle(worklist);
                return;
            }
            else
            {
                switch(prog[t.pc].code)
                {
                case IR.Wordboundary:
                    dchar back;
                    size_t bi;
                    //at start & end of input
                    if(atStart && wordTrie[front])
                    {
                        t.pc += IRL!(IR.Wordboundary);
                        break;
                    }
                    else if(atEnd && s.loopBack.nextChar(back, bi)
                            && wordTrie[back])
                    {
                        t.pc += IRL!(IR.Wordboundary);
                        break;
                    }
                    else if(s.loopBack.nextChar(back, index))
                    {
                        bool af = wordTrie[front] != 0;
                        bool ab = wordTrie[back] != 0;
                        if(af ^ ab)
                        {
                            t.pc += IRL!(IR.Wordboundary);
                            break;
                        }
                    }
                    recycle(t);
                    t = worklist.fetch();
                    break;
                case IR.Notwordboundary:
                    dchar back;
                    size_t bi;
                    //at start & end of input
                    if(atStart && !wordTrie[front])
                    {
                        recycle(t);
                        t = worklist.fetch();
                        break;
                    }
                    else if(atEnd && s.loopBack.nextChar(back, bi)
                            && !wordTrie[back])
                    {
                        recycle(t);
                        t = worklist.fetch();
                        break;
                    }
                    else if(s.loopBack.nextChar(back, index))
                    {
                        bool af = wordTrie[front] != 0;
                        bool ab = wordTrie[back]  != 0;
                        if(af ^ ab)
                        {
                            recycle(t);
                            t = worklist.fetch();
                            break;
                        }    
                    }
                    t.pc += IRL!(IR.Wordboundary);
                    break;
                case IR.Bol:
                    dchar back;
                    size_t bi;
                    //TODO: multiline & attributes, unicode line terminators
                    if(atStart)
                        t.pc += IRL!(IR.Bol);
                    else if(s.loopBack.nextChar(back,bi) && back == '\n') 
                        t.pc += IRL!(IR.Bol);
                    else
                    {
                        recycle(t);
                        t = worklist.fetch();
                    }
                    break;
                case IR.Eol:
                    debug(fred_matching) writefln("EOL (seen CR: %s, front 0x%x) %s", seenCr, front, s[index..s.lastIndex]);
                    //no matching inside \r\n
                    if(atEnd || ((front == '\n') ^ seenCr) || front == LS 
                       || front == PS || front == NEL)
                    {
                        t.pc += IRL!(IR.Eol);
                    }
                    else
                    {
                        recycle(t);
                        t = worklist.fetch();
                    }
                    break;
                case IR.InfiniteStart, IR.InfiniteQStart:
                    t.pc += prog[t.pc].data + IRL!(IR.InfiniteStart);
                    goto case IR.InfiniteEnd; // both Q and non-Q
                    break;
                case IR.RepeatStart, IR.RepeatQStart:
                    t.pc += prog[t.pc].data + IRL!(IR.RepeatStart);
                    goto case IR.RepeatEnd; // both Q and non-Q
                case IR.RepeatEnd:
                case IR.RepeatQEnd:
                    // len, step, min, max
                    uint len = prog[t.pc].data;
                    uint step =  prog[t.pc+1].raw;
                    uint min = prog[t.pc+2].raw;
                    if(t.counter < min)
                    {
                        t.counter += step;
                        t.pc -= len;
                        break;
                    }
                    uint max = prog[t.pc+3].raw;
                    if(t.counter < max)
                    {
                        if(prog[t.pc].code == IR.RepeatEnd)
                        {
                            //queue out-of-loop thread
                            worklist.insertFront(fork(t, t.pc + IRL!(IR.RepeatEnd),  t.counter % step));
                            t.counter += step;
                            t.pc -= len;
                        }
                        else
                        {
                            //queue into-loop thread
                            worklist.insertFront(fork(t, t.pc - len,  t.counter + step));
                            t.counter %= step;
                            t.pc += IRL!(IR.RepeatEnd);
                        }
                    }
                    else
                    {
                        t.counter %= step;
                        t.pc += IRL!(IR.RepeatEnd);
                    }
                    break;
                case IR.InfiniteEnd:
                case IR.InfiniteQEnd:
                    if(merge[prog[t.pc + 1].raw+t.counter] < genCounter)
                    {
                        debug(fred_matching) writefln("A thread(pc=%s) passed there : %s ; GenCounter=%s mergetab=%s",
                                        t.pc, index, genCounter, merge[prog[t.pc + 1].raw+t.counter] );
                        merge[prog[t.pc + 1].raw+t.counter] = genCounter;
                    }
                    else
                    {
                        debug(fred_matching) writefln("A thread(pc=%s) got merged there : %s ; GenCounter=%s mergetab=%s",
                                        t.pc, index, genCounter, merge[prog[t.pc + 1].raw+t.counter] );
                        recycle(t);
                        t = worklist.fetch();
                        break;
                    }
                    uint len = prog[t.pc].data;
                    uint pc1, pc2; //branches to take in priority order
                    if(prog[t.pc].code == IR.InfiniteEnd)
                    {
                        pc1 = t.pc - len;
                        pc2 = t.pc + IRL!(IR.InfiniteEnd);
                    }
                    else
                    {
                        pc1 = t.pc + IRL!(IR.InfiniteEnd);
                        pc2 = t.pc - len;
                    }
                    static if(withInput)
                    {
                        int test = quickTestFwd(pc1, front, re);
                        if(test > 0)
                        {
                            nlist.insertBack(fork(t, pc1 + test, t.counter));
                            t.pc = pc2;
                        }
                        else if(test == 0)
                        {
                            worklist.insertFront(fork(t, pc2, t.counter));
                            t.pc = pc1;
                        }
                        else
                            t.pc = pc2;
                    }
                    else
                    {
                        worklist.insertFront(fork(t, pc2, t.counter));
                        t.pc = pc1;
                    }
                    break;
                case IR.OrEnd:
                    if(merge[prog[t.pc + 1].raw+t.counter] < genCounter)
                    {
                        debug(fred_matching) writefln("A thread(pc=%s) passed there : %s ; GenCounter=%s mergetab=%s",
                                        t.pc, s[index..s.lastIndex], genCounter, merge[prog[t.pc + 1].raw+t.counter] );
                        merge[prog[t.pc + 1].raw+t.counter] = genCounter;
                        t.pc += IRL!(IR.OrEnd);
                    }
                    else
                    {
                        debug(fred_matching) writefln("A thread(pc=%s) got merged there : %s ; GenCounter=%s mergetab=%s",
                                        t.pc, s[index..s.lastIndex], genCounter, merge[prog[t.pc + 1].raw+t.counter] );
                        recycle(t);
                        t = worklist.fetch();
                    }
                    break;
                case IR.OrStart:
                    t.pc += IRL!(IR.OrStart);
                    goto case;
                case IR.Option:
                    uint next = t.pc + prog[t.pc].data + IRL!(IR.Option);
                    //queue next Option
                    if(prog[next].code == IR.Option)
                    {
                        worklist.insertFront(fork(t, next, t.counter));
                    }
                    t.pc += IRL!(IR.Option);
                    break;
                case IR.GotoEndOr:
                    t.pc = t.pc + prog[t.pc].data + IRL!(IR.GotoEndOr);
                    break;
                case IR.GroupStart: 
                    uint n = prog[t.pc].data;
                    t.matches.ptr[n].begin = cast(size_t)index;
                    t.pc += IRL!(IR.GroupStart);
                    //debug(fred_matching)  writefln("IR group #%u starts at %u", n, i);
                    break;
                case IR.GroupEnd:  
                    uint n = prog[t.pc].data;
                    t.matches.ptr[n].end = cast(size_t)index;
                    t.pc += IRL!(IR.GroupEnd);
                    //debug(fred_matching) writefln("IR group #%u ends at %u", n, i);
                    break;
                case IR.Backref:
                    uint n = prog[t.pc].data;
                    if(t.matches.ptr[n].begin == t.matches.ptr[n].end)//zero-width Backref!
                    {
                        t.pc += IRL!(IR.Backref);
                    }
                    else static if(withInput)
                    {
                        uint idx = t.matches.ptr[n].begin + t.uopCounter;
                        uint end = t.matches.ptr[n].end;
                        if(s[idx..end].front == front)
                        {
                           t.uopCounter += std.utf.stride(s[idx..end], 0);
                           if(t.uopCounter + t.matches.ptr[n].begin == t.matches.ptr[n].end)
                           {//last codepoint
                                t.pc += IRL!(IR.Backref);
                                t.uopCounter = 0;
                           }
                           nlist.insertBack(t);
                        }
                        else
                            recycle(t);
                        t = worklist.fetch();
                    }
                    else
                    {
                        recycle(t);
                        t = worklist.fetch();
                    }
                    break;
                case IR.LookbehindStart:
                case IR.NeglookbehindStart:
                    auto backMatcher = ThompsonMatcher!(Char, typeof(s.loopBack))(this, prog[t.pc..t.pc+prog[t.pc].data+1]);
                    backMatcher.freelist = freelist;
                    if(backMatcher.matchBack(t.matches) ^ (prog[t.pc].code == IR.LookbehindStart))
                    {
                        recycle(t);
                        t = worklist.fetch();
                    }
                    else
                        t.pc += prog[t.pc].data + IRL!(IR.LookbehindStart) + IRL!(IR.LookbehindEnd);
                    break;
                case IR.LookaheadEnd:
                case IR.NeglookaheadEnd:
                    assert(0);
                case IR.LookaheadStart:
                case IR.NeglookaheadStart:
                    break;
                case IR.LookbehindEnd:
                case IR.NeglookbehindEnd:
                    assert(0, "No lookaround for ThompsonVM yet!");
                case IR.Nop:
                    t.pc += IRL!(IR.Nop);
                    break;
                static if(withInput)
                {
                    case IR.OrChar://assumes IRL!(OrChar) == 1
                        uint len = prog[t.pc].sequence;
                        uint end = t.pc + len;
                        for(; t.pc<end; t.pc++)
                            if(prog[t.pc].data == front)
                                break;
                        if(t.pc != end)
                        {
                            t.pc = end;
                            nlist.insertBack(t);
                        }
                        else
                            recycle(t);
                        t = worklist.fetch();
                        break;
                    case IR.Char:
                        if(front == prog[t.pc].data)
                        {
                            // debug(fred_matching) writefln("IR.Char %s vs %s ", front, cast(dchar)prog[t.pc].data);
                            t.pc += IRL!(IR.Char);
                            nlist.insertBack(t);
                        }
                        else
                            recycle(t);
                        t = worklist.fetch();
                        break;
                    case IR.Any:
                        t.pc += IRL!(IR.Any);
                        nlist.insertBack(t);
                        t = worklist.fetch();
                        break;
                    case IR.Charset:
                        if(re.charsets[prog[t.pc].data][front])
                        {
                            debug(fred_matching) writeln("Charset passed");
                            t.pc += IRL!(IR.Charset);
                            nlist.insertBack(t);
                        }
                        else
                        {
                            debug(fred_matching) writeln("Charset notpassed");
                            recycle(t);
                        }
                        t = worklist.fetch();
                        break;
                    case IR.Trie:
                        if(re.tries[prog[t.pc].data][front])
                        {
                            debug(fred_matching) writeln("Trie passed");
                            t.pc += IRL!(IR.Trie);
                            nlist.insertBack(t);
                        }
                        else
                        {
                            debug(fred_matching) writeln("Trie notpassed");
                            recycle(t);
                        }
                        t = worklist.fetch();
                        break;
                    default:
                        assert(0, "Unrecognized instruction " ~ prog[t.pc].mnemonic);
                }
                else
                {
                    default:
                        recycle(t);
                        t = worklist.fetch();
                }

                }
            }
        }while(t);
    }
    ///match the input, evaluating IR backwards without searching
    bool matchBack(Group[] matches)
    {
        debug(fred_matching)
        {
            writeln("---------------matchBack-----------------");
        }
        next();
        assert(clist == ThreadList.init);
        assert(nlist == ThreadList.init);
        if(!atEnd)// if no char 
        {
            auto startT = createStart(index);
            startT.pc = re.ir.length-1;
            evalBack!true(startT, matches);
            for(;;)
            {
                genCounter++;
                debug(fred_matching)
                {
                    writefln("Threaded matching (backwards) threads at  %s", retro(s[index..s.lastIndex]));
                    foreach(t; clist[])
                    {
                        assert(t);
                        writef("pc=%s ",t.pc);
                        write(t.matches);
                        writeln();
                    }
                }
                for(Thread* t = clist.fetch(); t; t = clist.fetch())
                {
                    evalBack!true(t, matches);
                }
                if(matched && nlist.empty)
                {
                    debug(fred_matching) writeln("Stopped  matching before consuming full input");
                    break;//not a partial match for sure
                }
                clist = nlist;
                nlist = ThreadList.init;
                if(!next())
                    break;
            }
        }
        genCounter++; //increment also on each end
        debug(fred_matching) writefln("Threaded matching (backwards) threads at end");
        //try out all zero-width posibilities
        for(Thread* t = clist.fetch(); t; t = clist.fetch())
        {
            evalBack!false(t, matches);
        }
        return matched;
    }
     /++
        a version of eval that executes IR backwards
    +/
    void evalBack(bool withInput)(Thread* t, Group[] matches)
    {
        Bytecode[] prog = re.ir;
        ThreadList worklist;
        debug(fred_matching) writeln("Evaluating thread backwards");
        do
        {
            debug(fred_matching)
            {
                writef("\tpc=%s [", t.pc);
                foreach(x; worklist[])
                    writef(" %s ", x.pc);
                writeln("]");
            }
            debug(fred_matching) writeln(disassemble(prog, t.pc));
            switch(prog[t.pc].code)
            {
            case IR.Wordboundary:
                dchar back;
                size_t bi;
                //at start & end of input
                if(atStart && wordTrie[front])
                {
                    t.pc--;
                    break;
                }
                else if(atEnd && s.loopBack.nextChar(back, bi)
                        && wordTrie[back])
                {
                    t.pc--;
                    break;
                }
                else if(s.loopBack.nextChar(back, index))
                {
                    bool af = wordTrie[front] != 0;
                    bool ab = wordTrie[back] != 0;
                    if(af ^ ab)
                    {
                        t.pc--;
                        break;
                    }
                }
                recycle(t);
                t = worklist.fetch();
                break;
            case IR.Notwordboundary:
                dchar back;
                size_t bi;
                //at start & end of input
                if(atStart && !wordTrie[front])
                {
                    recycle(t);
                    t = worklist.fetch();
                    break;
                }
                else if(atEnd && s.loopBack.nextChar(back, bi)
                        && !wordTrie[back])
                {
                    recycle(t);
                    t = worklist.fetch();
                    break;
                }
                else if(s.loopBack.nextChar(back, index))
                {
                    bool af = wordTrie[front] != 0;
                    bool ab = wordTrie[back]  != 0;
                    if(af ^ ab)
                    {
                        recycle(t);
                        t = worklist.fetch();
                        break;
                    }    
                }
                t.pc--;
                break;
            case IR.Bol:
                dchar back;
                size_t bi;
                //TODO: multiline & attributes, unicode line terminators
                if(atStart)
                    t.pc--;
                else if(s.loopBack.nextChar(back,bi) && back == '\n') 
                    t.pc--;
                else
                {
                    recycle(t);
                    t = worklist.fetch();
                }
                break;
            case IR.Eol:
                debug(fred_matching) writefln("EOL (seen CR: %s, front 0x%x) %s", seenCr, front, s[index..s.lastIndex]);
                //no matching inside \r\n
                if(((front == '\n') ^ seenCr) || front == LS 
                    || front == PS || front == NEL)
                {
                    t.pc--;
                }
                else
                {
                    recycle(t);
                    t = worklist.fetch();
                }
                break;
            case IR.InfiniteStart, IR.InfiniteQStart:
                uint len = prog[t.pc].data;
                uint mIdx = t.pc + len + IRL!(IR.InfiniteEnd); // we're always pointed at the tail of instruction
                if(merge[prog[mIdx].raw+t.counter] < genCounter)
                {
                    debug(fred_matching) writefln("A thread(pc=%s) passed there : %s ; GenCounter=%s mergetab=%s",
                                    t.pc, index, genCounter, merge[prog[mIdx].raw+t.counter] );
                    merge[prog[mIdx].raw+t.counter] = genCounter;
                }
                else
                {
                    debug(fred_matching) writefln("A thread(pc=%s) got merged there : %s ; GenCounter=%s mergetab=%s",
                                    t.pc, index, genCounter, merge[prog[mIdx].raw+t.counter] );
                    recycle(t);
                    t = worklist.fetch();
                    break;
                }
                if(prog[t.pc].code == IR.InfiniteStart)//greedy
                {
                    worklist.insertFront(fork(t, t.pc-1, t.counter));
                    t.pc += len;
                }
                else
                {
                    worklist.insertFront(fork(t, t.pc+len, t.counter));
                    t.pc--;
                }
                break;
            case IR.InfiniteEnd:
            case IR.InfiniteQEnd://now it's a start
                uint len = prog[t.pc].data;
                t.pc -= len+IRL!(IR.InfiniteStart);
                assert(prog[t.pc].code == IR.InfiniteStart || prog[t.pc].code == IR.InfiniteQStart);
                goto case IR.InfiniteStart;
            case IR.RepeatStart, IR.RepeatQStart:
                uint len = prog[t.pc].data;
                uint tail = t.pc + len + 1;
                uint step =  prog[tail+1].raw;
                uint min = prog[tail+2].raw;
                uint max = prog[tail+3].raw;
                if(t.counter < min)
                {
                    t.counter += step;
                    t.pc += len;
                }
                else if(t.counter < max)
                {
                    if(prog[t.pc].code == IR.RepeatStart)//greedy
                    {
                        worklist.insertFront(fork(t, t.pc-1, t.counter%step));
                        t.counter += step;
                        t.pc += len;
                    }
                    else
                    {
                        worklist.insertFront(fork(t, t.pc + len, t.counter + step));
                        t.counter = t.counter%step;
                        t.pc--;
                    }
                }
                else
                {
                    t.counter = t.counter%step;
                    t.pc--;
                }
                break;
            case IR.RepeatEnd:
            case IR.RepeatQEnd:
                t.pc -= prog[t.pc].data+IRL!(IR.RepeatStart);
                assert(prog[t.pc].code == IR.RepeatStart || prog[t.pc].code == IR.RepeatQStart);
                goto case IR.RepeatStart;
            case IR.OrEnd:
                uint len = re.ir[t.pc].data;
                t.pc -= len;
                assert(re.ir[t.pc].code == IR.Option);
                len = re.ir[t.pc].data;
                t.pc = t.pc + len; //to IR.GotoEndOr or just before IR.OrEnd
                break;
            case IR.OrStart:
                uint len = prog[t.pc].data;
                uint mIdx = t.pc + len + IRL!(IR.OrEnd); //should point to the end of OrEnd
                if(merge[prog[mIdx].raw+t.counter] < genCounter)
                {
                    debug(fred_matching) writefln("A thread(t.pc=%s) passed there : %s ; GenCounter=%s mergetab=%s",
                                    t.pc, index, genCounter, merge[prog[mIdx].raw+t.counter] );
                    merge[prog[mIdx].raw+t.counter] = genCounter;
                }
                else
                {
                    debug(fred_matching) writefln("A thread(t.pc=%s) got merged there : %s ; GenCounter=%s mergetab=%s",
                                    t.pc, index, genCounter, merge[prog[mIdx].raw+t.counter] );
                    recycle(t);
                    t = worklist.fetch();
                    break;
                }
                t.pc--;
                break;
            case IR.Option:
                assert(re.ir[t.pc].code == IR.Option);
                t.pc += re.ir[t.pc].data + IRL!(IR.Option);
                if(re.ir[t.pc].code == IR.Option)
                {
                    t.pc--;//hackish, assumes size of IR.Option == 1
                    if(re.ir[t.pc].code == IR.GotoEndOr)
                    {
                        t.pc += re.ir[t.pc].data + IRL!(IR.GotoEndOr);
                    }
                }
                assert(re.ir[t.pc].code == IR.OrEnd);
                t.pc -= re.ir[t.pc].data + 1;
                break;
            case IR.GotoEndOr:
                assert(re.ir[t.pc].code == IR.GotoEndOr);
                uint npc = t.pc+IRL!(IR.GotoEndOr);
                assert(re.ir[npc].code == IR.Option);
                worklist.insertFront(fork(t, npc + re.ir[npc].data, t.counter));//queue next branch
                t.pc--;
                break;
            case IR.GroupStart: 
                uint n = prog[t.pc].data;
                t.matches.ptr[n].begin = index;
                t.pc--;
                //debug(fred_matching)  writefln("IR group #%u starts at %u", n, i);
                break;
            case IR.GroupEnd:  
                uint n = prog[t.pc].data;
                t.matches.ptr[n].end = index;
                t.pc--;
                //debug(fred_matching) writefln("IR group #%u ends at %u", n, i);
                break;
            case IR.Backref:
                uint n = prog[t.pc].data;
                if(t.matches.ptr[n].begin == t.matches.ptr[n].end)//zero-width Backref!
                {
                    t.pc--;
                }
                else static if(withInput)
                {
                    uint idx = t.matches.ptr[n].begin + t.uopCounter;
                    uint end = t.matches.ptr[n].end;
                    if(s[idx..end].front == front)//TODO: could be a BUG in backward matching
                    {
                        t.uopCounter += std.utf.stride(s[idx..end], 0);
                        if(t.uopCounter + t.matches.ptr[n].begin == t.matches.ptr[n].end)
                        {//last codepoint
                            t.pc--;
                            t.uopCounter = 0;
                        }
                        nlist.insertBack(t);
                    }
                    else
                        recycle(t);
                    t = worklist.fetch();
                }
                else
                {
                    recycle(t);
                    t = worklist.fetch();
                }
                break;
          
            case IR.LookbehindStart:
            case IR.NeglookbehindStart:
                finish(t, matches, 1);
                recycle(t);
                //cut off low priority threads
                recycle(clist);
                recycle(worklist);
                return;
            case IR.LookaheadStart:
            case IR.NeglookaheadStart:
            case IR.LookaheadEnd:
            case IR.NeglookaheadEnd:
            case IR.LookbehindEnd:
            case IR.NeglookbehindEnd:
                assert(0, "No lookaround inside look back");
            case IR.Nop:
                t.pc--;
                break;
            static if(withInput)
            {
                case IR.OrChar://assumes IRL!(OrChar) == 1
                    uint len = prog[t.pc].sequence;
                    uint end = t.pc - len;
                    for(; t.pc>end; t.pc--)
                        if(prog[t.pc].data == front)
                            break;
                    if(t.pc != end)
                    {
                        t.pc = end;
                        nlist.insertBack(t);
                    }
                    else
                        recycle(t);
                    t = worklist.fetch();
                    break;
                case IR.Char:
                    if(front == prog[t.pc].data)
                    {
                        // debug(fred_matching) writefln("IR.Char %s vs %s ", front, cast(dchar)prog[t.pc].data);
                        t.pc--;
                        nlist.insertBack(t);
                    }
                    else
                        recycle(t);
                    t = worklist.fetch();
                    break;
                case IR.Any:
                    t.pc--;
                    nlist.insertBack(t);
                    t = worklist.fetch();
                    break;
                case IR.Charset:
                    if(re.charsets[prog[t.pc].data][front])
                    {
                        debug(fred_matching) writeln("Charset passed");
                        t.pc--;
                        nlist.insertBack(t);
                    }
                    else
                    {
                        debug(fred_matching) writeln("Charset notpassed");
                        recycle(t);
                    }
                    t = worklist.fetch();
                    break;
                case IR.Trie:
                    if(re.tries[prog[t.pc].data][front])
                    {
                        debug(fred_matching) writeln("Trie passed");
                        t.pc--;
                        nlist.insertBack(t);
                    }
                    else
                    {
                        debug(fred_matching) writeln("Trie notpassed");
                        recycle(t);
                    }
                    t = worklist.fetch();
                    break;
                default:
                    assert(prog[t.pc].code < 0x80, "Unrecognized instruction " ~ prog[t.pc].mnemonic);
                    t.pc--;
            }
            else
            {
                default:
                    recycle(t);
                    t = worklist.fetch();
            }
            }
        }while(t);
    }
    ///get a dirty recycled Thread
    Thread* allocate()
    {
        if(freelist)
        {
            Thread* t = freelist;
            freelist = freelist.next;
            return t;
        }
        else
        {
            reserve(threadAllocSize);
            debug(fred_allocation) writefln("Allocated space for another %d threads", threadAllocSize);
            return allocate();
        }
    }
    ///
    void reserve(uint size)
    {
        assert(re.ngroup);
        const tSize = (Thread.sizeof+(re.ngroup-1)*Group.sizeof);
        void[] mem = new void[tSize*size];
        freelist = cast(Thread*)&mem[0];
        size_t i;
        for(i=tSize; i<tSize*size; i+=tSize)
            (cast(Thread*)&mem[i-tSize]).next = cast(Thread*)&mem[i];
        (cast(Thread*)&mem[i-tSize]).next = null;
    }
    ///dispose a thread
    void recycle(Thread* t)
    {
        t.next = freelist;
        freelist = t;
    }
    //dispose list of threads
    void recycle(ref ThreadList list)
    {
        auto t = list.tip;
        while(t)
        {
            auto next = t.next;
            recycle(t);
            t = next;
        }
        list = list.init;
    }
    ///creates a copy of master thread with given pc
    Thread* fork(Thread* master, uint pc, size_t counter)
    {
        auto t = allocate();
        t.matches.ptr[0..re.ngroup] = master.matches.ptr[0..re.ngroup]; //TODO: Small array optimization and/or COW
        t.pc = pc;
        t.counter = counter;
        t.uopCounter = 0;
        return t;
    }
    ///creates a start thread
    Thread*  createStart(size_t index)
    {
        auto t = allocate();
        t.matches.ptr[0..re.ngroup] = Group.init; //TODO: ditto
        t.matches[0].begin = index;
        t.pc = 0;
        t.counter = 0;
        t.uopCounter = 0;
        return t;
    }
}

//
struct Captures(R)
//    if(isSomeString!R)
{
    R input;
    Group[] matches;
    uint f, b;
    Program re;
    this(alias Engine)(ref RegexMatch!(R,Engine) rmatch)
    {
        input = rmatch.input;
        matches = rmatch.matches;
        re = rmatch.engine.re;
        b = matches.length;
        f = 0;
    }
    ///
    @property R pre() 
    {
        return empty ? input[] : input[0 .. matches[0].begin];
    }
    ///
    @property R post() 
    {
        return empty ? input[] : input[matches[0].end .. $];
    }
    ///
    @property R hit() 
    {
        assert(!empty);
        return input[matches[0].begin .. matches[0].end];
    }
    ///iteration means
    @property R front() 
    {
        assert(!empty);
        return input[matches[f].begin .. matches[f].end];
    }
    ///ditto
    @property R back() 
    {
        assert(!empty);
        return input[matches[b-1].begin .. matches[b-1].end];
    }
    ///ditto
    void popFront()
    {   
        assert(!empty);
        ++f;   
    }
    ///ditto
    void popBack()
    {
        assert(!empty);
        --b;   
    }
    ///ditto
    @property bool empty() const { return f >= b; }
    
    R opIndex()(size_t i) /*const*/ //@@@BUG@@@
    {
        assert(f+i < b,"requested submatch number is out of range");
        return input[matches[f+i].begin..matches[f+i].end];
    }
    
    R opIndex(String)(String i) /*const*/ //@@@BUG@@@
        if(isSomeString!String)
    {
        size_t index = re.lookupNamedGroup(i);
        return opIndex(index);
    }
    @property size_t length() const { return b-f;  }
}

/**
*/
struct RegexMatch(R, alias Engine = BacktrackingMatcher)
    if(isSomeString!R)
{
private:
    R input;
    Group[] matches;
    bool _empty;
    uint flags;
    NamedGroup[] named;
    alias Unqual!(typeof(R.init[0])) Char;
    alias Engine!Char EngineType;
    EngineType engine;
    
public:
    ///
    this(Program prog, R _input)
    {
        input = _input;
        matches = new Group[prog.ngroup];
        engine = EngineType(prog, Input!Char(input));
        _empty = !engine.match(matches);
    }
    ///
    @property R pre()
    {
        return empty ? input[] : input[0 .. matches[0].begin];
    }
    ///
    @property R post()
    {
        return empty ? input[] : input[matches[0].end .. $];
    }
    ///
    @property R hit()
    {
        assert(!empty);
        return input[matches[0].begin .. matches[0].end];
    }
    ///
    @property ref front()
    {
        return this;
    }
    ///
    void popFront()
    { //previous one can have escaped references from Capture object
        matches = new Group[matches.length];
        _empty = !engine.match(matches);
    }
    ///
    @property bool empty(){ return _empty; }
    ///
    @property auto captures(){ return Captures!R(this); }
}

///
auto regex(S, S2=string)(S pattern, S2 flags=[])
    if(isSomeString!S && isSomeString!S2)
{
    if(!__ctfe)
    {
        auto parser = Parser!(typeof(pattern))(pattern, flags);
        Regex!(Unqual!(typeof(S.init[0]))) r = parser.program;
        return r;
    }
    else
    {
        auto parser = Parser!(typeof(pattern), true)(pattern, flags);
        Regex!(Unqual!(typeof(S.init[0]))) r = parser.program;
        return r;
    }
}

///
auto match(R)(R input, Program re)
{
    return RegexMatch!(Unqual!(typeof(input)))(re, input);
}
///ditto
auto match(R, String)(R input, String pat)
    if(isSomeString!String)
{
    return RegexMatch!(Unqual!(typeof(input)))(regex(pat), input);
}

///
auto tmatch(R)(R input, Program re)
{
    return RegexMatch!(Unqual!(typeof(input)),ThompsonMatcher)(re, input);
}
///ditto
auto tmatch(R, String)(R input, String pat)
    if(isSomeString!String)
{
    return RegexMatch!(Unqual!(typeof(input)),ThompsonMatcher)(regex(pat), input);
}

///
R replace(R, alias scheme=match)(R input, Program re, R format)
    if(isSomeString!R)
{
    auto app = appender!(R)();
    auto matches = scheme(input, re);
    size_t offset = 0;
    foreach(ref m; matches)
    {
        app.put(m.pre[offset .. $]);
        replaceFmt(format, m.captures, app);
        offset = m.pre.length + m.hit.length;
    }
    app.put(input[offset .. $]);
    return app.data;
}

///
R replace(alias fun, R,alias scheme=match)(R input, Program re)
    if(isSomeString!R)
{
    auto app = appender!(R)();
    auto matches = scheme(input, re);
    size_t offset = 0;
    foreach(m; matches)
    {
        app.put(m.pre[offset .. $]);
        app.put(fun(m));
        offset = m.pre.length + m.hit.length;
    }
    app.put(input[offset .. $]);
    return app.data;
}

///produce replacement string from format using captures for substitue
void replaceFmt(R, OutR)(R format, Captures!R captures, OutR sink, bool ignoreBadSubs=false)
    if(isOutputRange!(OutR, ElementEncodingType!R[]))
{
    enum State { Normal, Escape, Dollar };
    auto state = State.Normal;
    size_t offset;
L_Replace_Loop:
    while(!format.empty)
        final switch(state)
        {
        case State.Normal:
            for(offset = 0; offset < format.length; offset++)//no decoding
            {
                switch(format[offset])
                {
                case '\\':
                    state = State.Escape;
                    sink.put(format[0 .. offset]);
                    format = format[offset+1 .. $];// safe since special chars are ascii only
                    continue L_Replace_Loop;
                case '$':
                    state = State.Dollar;
                    sink.put(format[0 .. offset]);
                    format = format[offset+1 .. $];//ditto
                    continue L_Replace_Loop;
                default: 
                }
            }
            sink.put(format[0 .. offset]);
            format = format[offset .. $];
            break;
        case State.Escape:
            offset = std.utf.stride(format, 0);
            sink.put(format[0 .. offset]);
            format = format[offset .. $];
            state = State.Normal;
            break;
        case State.Dollar:
            if(ascii.isDigit(format[0]))
            {
                uint digit = parse!uint(format);
                enforce(ignoreBadSubs || digit < captures.length, text("invalid submatch number ", digit));
                if(digit < captures.length)                    
                    sink.put(captures[digit]);
            }
            else if(format[0] == '{') 
            {
                auto x = find!"!std.ascii.isAlpha(a)"(format[1..$]);
                enforce(!x.empty && x[0] == '}', "no matching '}' in replacement format");
                auto name = format[1 .. $ - x.length];
                format = x[1..$];
                enforce(!name.empty, "invalid name in ${...} replacement format");
                sink.put(captures[name]);
            }
            else if(format[0] == '&')
            {
                sink.put(captures[0]);
                format = format[1 .. $];
            }
            else if(format[0] == '`')
            {
                sink.put(captures.pre);
                format = format[1 .. $];
            }
            else if(format[0] == '\'')
            {
                sink.put(captures.post);
                format = format[1 .. $];
            }
            else if(format[0] == '$')
            {
                sink.put(format[0 .. 1]);
                format = format[1 .. $];
            }
            state = State.Normal;
            break;
        }
    enforce(state == State.Normal, "invalid format string in regex replace");
}

/**
Range that splits another range using a regular expression as a
separator.

Example:
----
auto s1 = ", abc, de,  fg, hi, ";
assert(equal(splitter(s1, regex(", *")),
    ["", "abc", "de", "fg", "hi", ""]));
----
 */
struct Splitter(Range, alias Engine=ThompsonMatcher)
    if(isSomeString!Range)
{
    Range _input;
    size_t _offset;
    alias RegexMatch!(Range, Engine) Rx; 
    Rx _match;

    this(Range input, Program separator)
    {
        _input = input;
        separator.flags |= RegexOption.global;
        if (_input.empty)
        {
            // there is nothing to match at all, make _offset > 0
            _offset = 1;
        }
        else
        {
            _match = Rx(separator, _input);
        }
    }

    auto ref opSlice()
    {
        return this.save();
    }
    ///
    @property Range front()
    {
        assert(!empty && _offset <= _match.pre.length
                && _match.pre.length <= _input.length);
        return _input[_offset .. min($, _match.pre.length)];
    }
    ///
    @property bool empty()
    {
        return _offset > _input.length;
    }
    ///
    void popFront()
    {
        assert(!empty);
        if (_match.empty)
        {
            // No more separators, work is done here
            _offset = _input.length + 1;
        }
        else
        {
            // skip past the separator
            _offset = _match.pre.length + _match.hit.length;
            _match.popFront;
        }
    }
    ///
    @property auto save()
    {
        return this;
    }
}

/// Ditto
Splitter!(Range) splitter(Range)(Range r, Program pat)
    if (is(Unqual!(typeof(Range.init[0])) : dchar))
{
    return Splitter!(Range)(r, pat);
}
///
String[] split(String)(String input, Program rx)
    if(isSomeString!String)
{
    auto a = appender!(String[])();
    foreach(e; splitter(input, rx))
        a.put(e);
    return a.data;
}

/// Exception object thrown in case of any errors during regex compilation
class RegexException : Exception
{
    this(string msg)
    {
        super(msg);
    }
}