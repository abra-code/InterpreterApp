#!/usr/bin/perl
# pdf_text_usable.pl - garbage gate for text extracted from a PDF. Called by pdf_text_is_usable in
# lib.interp.sh (convert_to_plain_text's PDF branch). A PDF whose fonts lack a usable ToUnicode map
# extracts as one placeholder glyph repeated (PDFKit emits U+00FF, or the replacement char), so a
# single character dominates the output; real text - in any script - never concentrates on one
# character. This is kept as a separate file rather than composed inline in the shell handler.
#
#   usage: perl pdf_text_usable.pl <extracted-text-file>
#   exit 0 = text is usable, exit 1 = looks like garbage (or unreadable).
#
# Whitespace and common leader/rule filler (. _ = * - middot ellipsis) are excluded from the count,
# so a dot-leader table of contents or an underscore fill-in form is not mistaken for garbage. Texts
# with very little real content (under 12 counted characters) are accepted, since a ToUnicode-less
# PDF produces far more than that - short signs/labels like "EXIT" pass; a truly empty extraction is
# left to the caller's separate whitespace check ("Nothing to translate").
#
# No 'use warnings': the extracted text may contain invalid byte sequences (itself a garbage
# signal), and we want silent U+FFFD replacement, not a warning per bad character.

use strict;

my $path = shift @ARGV;
defined $path or exit 1;
open(my $fh, '<:encoding(UTF-8)', $path) or exit 1;

my %freq;
my $total = 0;
while (my $line = <$fh>) {
    for my $c (split //, $line) {
        next if $c =~ /\s/;
        next if $c =~ /[._=*\x{2026}\x{00b7}-]/;
        $freq{$c}++;
        $total++;
    }
}
close($fh);

exit 0 if $total < 12;

my $max = 0;
for (values %freq) { $max = $_ if $_ > $max; }
exit(($max * 100 > $total * 60) ? 1 : 0);
