### text score

- This is a pure-text score notation.  It renders down to tracklang, but
because it's just text there has to be more complicated mechanism for
rhythm.

- It should also support sub-languages, e.g. pakhawaj bols.

- There could be a text based interface that either uses a REPL or a text
file.  This would be basically just 'seq' without any open windows.

- Scores in this notation should be fully compatible with tracklang, and
it should be possible to integrate into a block.

- However, it can represent things that are awkward in the gui score,
such as truly per-note controls and lots of use of parent tracks.

- Syntax examples: lilypond, <https://github.com/alda-lang/alda>
MML: <http://www.nullsleep.com/treasure/mck_guide/>

- Mridangam: <http://korvai.org/notation/notation-html/index.html>

### integration

There are three levels of DSL:

- DSL: Totally separate language, with its own parser and compiler.  `ky` is
one of these.

- TH: Separate language, but uses TH quasiquotes to interpolate haskell.  The
advantage is that I get variables, typechecking, debugging, and testing from
haskell.  Also, presuming they all compile down to the same intermediate form
(perhaps just NoteDeriver), they can all coexist in the same file, or even same
expression.  The disadvantage is that I have to deal with TH and probably needs
a compile and relink.  Well, I could probably dynamically load, but it's
complicated.

- EDSL: Plain haskell, with a special prelude with specialized operators and
the like.  `Derive.Solkattu.Score` does this.  The advantages are the full
power of haskell and ghci.  Disadvantages are the same as TH, only less awkward
than TH, but it can be hard to get a succinct syntax in haskell.

I can use the same mechanism as the local ky definitions, presumably in the
same file.  Text-defined score should integrate with the graphical score, so
I can use which is most convenient.  For example, text-defined calls should
provide CallDuration, so the GUI can automatically size their events.  I still
have the problem where a duration change bubbles up through each level, but it
only affects the GUI stages.

Even just a simple sequencing language could be pretty useful.

In theory, in the distant future, with some editor integration I could use the
tempo map and playback thread to highlight currently playing expressions.

### implementation

Initial implementation in `Derive/Text`.

If I wind up using a lot of text, I could store this as a normal file, or group
of files, inside of .git.  If I then use a "checked out" repo, I can use diff.

It could also be more convenient to always have an editor open, rather than
editing through the REPL.  This would basically be the same as the imported
.ky file, except it also imports from inside the git repo, and save would need
to notice a change to the files and commit them.

I could have a text language which is rendered to a block automatically.  The
block is read-only and can only be rederived from the text, but it gives a
visualization of the time, and a place to put the play cursor.  Its ruler could
also be automatically derived as a concatenation of the rulers underneath.
This would solve the problem of sequencing, but also integrate with the
graphical score.

Currently ^z sets a call to its "natural" duration, but won't move other
events.  I could have a version that does insert or delete time as appropriate.
It might have to extend the block length though, which in turn can cause its
callers to change size.  Perhaps there could be a notion of "open" blocks,
which know how to generate their own ruler, and automatically set their
end to the end of the last event.

### rhythm

Rhythm could either be multiplicative, proportional, additive, or based on beat
markers ala gongche:

```
dur=mult  c4 a b8 c _4 d4
==> [(0, 1/4, "c"), (1/4, 2/4, "a"), (4/8, 5/8, "b"), (5/8, 6/8, "c"),
    (1, 1+1/4, "d")]

dur=prop  c - a - b c _ _ d -
==> [(0, 2, "c"), (2, 2, "a"), (4, 1, "b"), (5, 1, "c"), (8, 2, "d")]

dur=add   c2 a b1 c _2 d2
==> [(0, 2, "c"), (2, 2, "a"), (4, 1, "b"), (5, 1, "c"), (8, 2, "d")]

dur=mark  c a | a b - c
==> [(0, 1/2, "c"), (1/2, 1/2, "a"), (1, 1/4, "a"), (1+1/4, 2/4, "b"),
    (1+3/4, 1/4, "c")]
```

dur=mult style understands dots and ties.  Also, for mult, proportional, and
additive, barlines check the rhythm, while for mark they mark beats.
check the rhythm:

So the job of this level is to figure out note start and duration.  This means
separate the note from rhythm, and maintain the current duration and implicit
duration.  It understands rests _, and needs a meter if there are barline
checks, or a base speed for proportional or mark.  In fact, I think
proportional is just additive with a hardcoded duration, so maybe if I add -
to additive as a duration extension, then I only need one.

Tuplets:

> t[a b c]2

This becomes a call to 't' with a track of three notes as subs:

> [(0, 2, Parent "t" [(0, 1, "a"), (1, 1, "b"), (2, 1, "c")])]

Later this turns into a call to 't' with sub-tracks.

### pitch

The next step is to infer pitches.  The octave is inferred based on the
shortest distance, which , or ' suffixes can override.

How to do implicit octaves if the scale is abstract?  I could have a
'parse_degree' like I have 'parse_pitch'.

### instrument

I need to give access to c_equal so I can set scale, instrument, and the like.
How about a=b [ ... ] will wrap the contained score in a Derive.with_val, or
configure parsing, based on the key name.  So

> dur=add [ scale=legong [ inst=gangsa [ ... ]]]

Or I could chain those to avoid extra brackets:

> dur=add scale=legong inst=gangsa [ ... ]

### conversion

The last step is to convert to a deriver.  Input will be:

```
type Score = [(ScoreTime, ScoreTime, Note)]
data Note = Parent Symbol Score | Pitch Octave Symbol
type Octave = Int
```

Since I don't have a separate pitch track, how do I distinguish pitch calls
from note calls?  I can first look in the scale, and if not found, then treat
it as a note call.


Alternately, what about doing this all as a haskell DSL?  It seems to work
ok for Derive.Solkattu.Score.  To avoid having "s everywhere, I would have to
add a variable for each call, e.g. for each scale degree and ornament, and
then have some operators to combine them.  I'd still need an operator to join
each note, so at minimum it would look like:

> a . o . a . u .|. s2 (a . i) . o . a . i .|. mempty

Not very nice.  It works for solkattu but that seems like more limited domain.
Otherwise, I can make a bunch of quasiquoters with a common output:

> garuda = [bali| a4 o a u | a2 i o4 a i |]

But how is this different from just an embedded string:

> garuda = parse_bali "a4 o a u | a2 i o4 a i"

I guess not, except that I don't need to escape quotes, and can make compile
time errors.

Wait, I want to be able to substitute in haskell variables.

### examples

Legong Keraton, Garuda section:

```
                i oioioieo  oia
 i a i o| o a a i| i a i o| o a a i|
 1 6 1 2| 2 6 6 1| 1 6 1 2| 2 6 6 1|
```

Solkattu:

```
dur=add
dit2 - thom - | na1 ka ti ku ta ri ki ta | dhom2 - tat - | din - - - |
k2 - i - | n1 + u + k t + k | o2 - k - | D - - - |
```

```
mode=kharaharapriya
p|ss s srs|rsrsnnsn|snsnddnd|d-ndggps|
p | s s - s - s r s | r s r s n n s n | s n s n d d n d | d ~ n d g g p s |

+harm/p 

```

Additive rhythm:


+a/5/1 => ("+a", "5", 1)


Multiple tracks:

Chords

Alignment
