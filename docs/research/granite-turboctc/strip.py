import re

# Make an already-formatted transcript look like raw CTC output: lowercase,
# no sentence punctuation. Two things are deliberately preserved:
#
#  - CONTRACTIONS. The punct/cap model's label set is only . , ? plus
#    <ACRONYM> — it has no apostrophe and can never re-create "I'm". Removing
#    them here would handicap any source that already emits them.
#  - DIGIT-INTERNAL SEPARATORS. "5,000" and "3.1" are numbers, not sentence
#    punctuation. Stripping those turns them into "5 000" and "3 1", which the
#    model then re-punctuates as prose. Protect, strip, restore.
_PROT = re.compile(r"(?<=[0-9])([.,])(?=[0-9])")
_STRIP = re.compile(r"""[.,?!;:"()\[\]]""")


def strip_fmt(s):
    s = s.lower()
    s = _PROT.sub(lambda m: " QQDOT " if m.group(1) == "." else " QQCOM ", s)
    s = _STRIP.sub(" ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s.replace(" QQDOT ", ".").replace(" QQCOM ", ",")
