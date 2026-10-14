#!/usr/bin/perl
# transform_check.pl - post-run check of a text transformer's output against its source.
#   usage: perl transform_check.pl <source file> <result file>
# Prints one human-readable line describing what looks wrong, or nothing when the check passes.
# Exit status is always 0 for a completed check; a non-zero exit means the files could not be read.
#
# Three checks, all deliberately crude and cheap:
#   - missing numbers: every number in the source (digits with optional , or . groups) must appear
#     in the result as a whole number - "14" inside "140" does not count. Thousands separators are
#     ignored on both sides, so "18,600" matches "18600". A rewrite that spells a number out ("one
#     third") is reported too; that is a false alarm the user can dismiss, while a silently changed
#     figure is the failure this exists to catch.
#   - new numbers: a number in the result that the source does not have. The spike caught the
#     Humanizer turning "July" of a 2025 report into "July of 2022", and a small rewriter adding
#     "(932,000 miles)" - neither drops a number, so only this direction sees them. Spelled-out
#     source numbers written as digits ("tenth" -> "10th") are the false alarm here.
#     English number words in the source ("four", "tenth") count as present, which removes most of
#     those. A digit right after a Latin letter ("k8s", "Q3") is part of a name, not a number, on
#     both sides - Latin only, because Chinese writes digits directly after Han characters (据2024年).
#   - script switch: the Humanizer card documents short English drafts sometimes coming back in
#     Chinese. Reported when the share of Han characters among letters jumps across 30% either way.
#   - much shorter: a result with under 60% of the source's letters has probably dropped content
#     (the spike saw a whole paragraph vanish, with no number in it for the checks above to miss).
#     Measured on the spike's 43 Humanizer rewrites: they ran from 70% to 111% of the source.
use strict;
use warnings;

binmode STDOUT, ':encoding(UTF-8)';

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:encoding(UTF-8)', $path) or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return defined $text ? $text : '';
}

# English number words, cardinal and ordinal, as the digits they stand for.
my %WORD_NUMBER;
{
    my @ones = qw(zero one two three four five six seven eight nine ten eleven twelve thirteen
                  fourteen fifteen sixteen seventeen eighteen nineteen twenty);
    my @ord  = qw(zeroth first second third fourth fifth sixth seventh eighth ninth tenth eleventh
                  twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth
                  nineteenth twentieth);
    $WORD_NUMBER{$ones[$_]} = $_ for 0 .. $#ones;
    $WORD_NUMBER{$ord[$_]}  = $_ for 0 .. $#ord;
    my %tens = (thirty => 30, forty => 40, fifty => 50, sixty => 60, seventy => 70, eighty => 80,
                ninety => 90, hundred => 100, thousand => 1000, million => 1000000);
    $WORD_NUMBER{$_} = $tens{$_} for keys %tens;
}

sub letter_count {
    my ($text) = @_;
    my $n = () = $text =~ /\p{L}/g;
    return $n;
}

sub han_share {
    my ($text) = @_;
    my $letters = () = $text =~ /\p{L}/g;
    return 0 if $letters == 0;
    my $han = () = $text =~ /\p{Han}/g;
    return $han / $letters;
}

my ($source_path, $result_path) = @ARGV;
exit 2 unless defined $source_path && defined $result_path;
my $source = slurp($source_path);
my $result = slurp($result_path);
exit 2 unless defined $source && defined $result;

my @problems;

my $src_han = han_share($source);
my $res_han = han_share($result);
if ($src_han < 0.3 && $res_han >= 0.3) {
    push @problems, 'the result switched to Chinese';
} elsif ($src_han >= 0.3 && $res_han < 0.3) {
    push @problems, 'the result switched away from Chinese';
}

# Numbers present in the result, normalized (thousands commas removed).
my %have;
while ($result =~ /(?<![\d\p{Latin}])(?<!\d[.,])(\d+(?:[.,]\d+)*)(?!\d)/g) {
    my $n = $1;
    $n =~ s/,(?=\d{3}(?!\d))//g;
    $have{$n} = 1;
}
my (@missing, %seen);
while ($source =~ /(?<![\d\p{Latin}])(?<!\d[.,])(\d+(?:[.,]\d+)*)(?!\d)/g) {
    my $raw = $1;
    my $n = $raw;
    $n =~ s/,(?=\d{3}(?!\d))//g;
    next if $seen{$n}++;
    push @missing, $raw unless $have{$n};
}
# Spelled-out numbers in the source vouch for the same number written as digits in the result.
my %spelled;
while ($source =~ /\b(\p{L}+)\b/g) {
    my $w = lc $1;
    $spelled{$WORD_NUMBER{$w}} = 1 if exists $WORD_NUMBER{$w};
}
my (@added, %added_seen);
while ($result =~ /(?<![\d\p{Latin}])(?<!\d[.,])(\d+(?:[.,]\d+)*)(?!\d)/g) {
    my $raw = $1;
    my $n = $raw;
    $n =~ s/,(?=\d{3}(?!\d))//g;
    next if $seen{$n} || $spelled{$n} || $added_seen{$n}++;
    push @added, $raw;
}
if (@missing) {
    my $count = scalar @missing;
    my @shown = @missing > 5 ? (@missing[0 .. 4], '...') : @missing;
    push @problems, ($count == 1 ? '1 number from the original is missing' : "$count numbers from the original are missing")
        . ': ' . join(', ', @shown);
}

if (@added) {
    my $count = scalar @added;
    my @shown = @added > 5 ? (@added[0 .. 4], '...') : @added;
    push @problems, ($count == 1 ? '1 number is not in the original' : "$count numbers are not in the original")
        . ': ' . join(', ', @shown);
}

my $src_letters = letter_count($source);
my $res_letters = letter_count($result);
if ($src_letters >= 200 && $res_letters < 0.6 * $src_letters) {
    push @problems, sprintf('the result is much shorter than the original (%d%%), so text may be missing',
        100 * $res_letters / $src_letters);
}

if (@problems) {
    my $line = join('; ', @problems);
    print 'Check: ', ucfirst($line), ".\n";
}
exit 0;
