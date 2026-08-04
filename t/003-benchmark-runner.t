use strict;
use warnings;

use Cwd qw(abs_path);
use File::Spec;
use FindBin;
use Test::More;

my $root = abs_path(File::Spec->catdir($FindBin::Bin, '..'));

sub slurp {
    my ($path) = @_;
    return '' if !-f $path;

    open my $fh, '<', $path or die "failed to open $path: $!";
    local $/;
    return <$fh>;
}

my $makefile = File::Spec->catfile($root, 'Makefile');
my $runner = File::Spec->catfile($root, 'benchmark', 'run.sh');
my $fold = File::Spec->catfile($root, 'benchmark', 'fold.sh');
my $cases_file = File::Spec->catfile($root, 'benchmark', 'cases.txt');
my $bench_lua = File::Spec->catfile($root, 'benchmark', 'lua', 'bench.lua');
my $target_template = File::Spec->catfile($root, 'benchmark', 'conf', 'target.nginx.conf');
my $upstream_template = File::Spec->catfile($root, 'benchmark', 'conf', 'upstream.nginx.conf');
my $wrk_headers = File::Spec->catfile($root, 'benchmark', 'wrk', 'headers.lua');
my $readme = File::Spec->catfile($root, 'benchmark', 'README.md');

ok(-f $makefile, 'Makefile exists');
like(slurp($makefile), qr/^bench:\s*$/m, 'Makefile defines bench target');
like(slurp($makefile), qr{\./benchmark/run\.sh}, 'bench target delegates to benchmark/run.sh');

ok(-x $runner, 'benchmark/run.sh exists and is executable');
ok(-x $fold, 'benchmark/fold.sh exists and is executable');

my $runner_src = slurp($runner);

like($runner_src, qr/BENCH_DRY_RUN/, 'runner supports dry-run mode');
like($runner_src, qr/CPU_SATURATION_THRESHOLD/, 'runner checks CPU saturation');
like($runner_src, qr/WRK2_BIN/, 'runner uses wrk2 binary configuration');
like($runner_src, qr/WRK_RATE/, 'runner supports wrk2 target rate');
like($runner_src, qr/WRK_CONNECTIONS="\$\{WRK_CONNECTIONS:-100\}"/,
    'runner defaults wrk2 connections to 100');
like($runner_src, qr/KEEPALIVE_POOL_SIZE="\$\{KEEPALIVE_POOL_SIZE:-120\}"/,
    'runner defaults keepalive pool size above wrk2 connections');
like($runner_src, qr/\s-U\s/, 'runner requests wrk2 uncorrected latency output');
like($runner_src, qr/-R "\$rate"/, 'runner passes a wrk2 target rate');

# the case table replaces the hardcoded case list
like($runner_src, qr/BENCH_CASES=/, 'runner drives cases from BENCH_CASES');
like($runner_src, qr/BENCH_REPEATS="\$\{BENCH_REPEATS:-5\}"/,
    'runner defaults to five repeats');
like($runner_src, qr/WRK_WARMUP/, 'runner runs a discarded warmup');
like($runner_src, qr/RESULTS_CSV/, 'runner writes one CSV row per run');
like($runner_src, qr/fairness_audit/, 'runner audits request fairness');
like($runner_src, qr/latency_phase/, 'runner has a separate fixed-rate latency phase');
like($runner_src, qr/throughput_phase/, 'runner has a throughput phase');

ok(-f $cases_file, 'benchmark/cases.txt exists');
ok(-f $bench_lua, 'benchmark/lua/bench.lua exists');

# Every shape must exist on both sides, or the comparison is not a comparison.
my @cases = grep { length } map {
    my $line = $_;
    $line =~ s/#.*//;
    $line =~ s/\s+//g;
    $line;
} split /\n/, slurp($cases_file);

ok(scalar(@cases) > 0, 'cases.txt lists cases');

my %by_shape;
for my $name (@cases) {
    my ($driver, $shape) = split /\./, $name, 2;
    $by_shape{$shape}{$driver} = 1;
}

my @unpaired = grep { !($by_shape{$_}{ffi} && $by_shape{$_}{resty}) }
    sort keys %by_shape;
is(scalar(@unpaired), 0, 'every shape has both an ffi and a resty case')
    or diag('unpaired shapes: ' . join(', ', @unpaired));

# cases.txt is the source of truth the runner generates locations from; bench.lua
# must define the same shapes. The running worker is diffed against this file at
# smoke-check time too, but a static check fails faster.
my $bench_src = slurp($bench_lua);
my @declared = $bench_src =~ /pair_case\("([a-z0-9_]+)"/g;
my %declared = map { $_ => 1 } @declared;

my @missing = grep { !$declared{$_} } sort keys %by_shape;
is(scalar(@missing), 0, 'bench.lua defines every shape listed in cases.txt')
    or diag('missing from bench.lua: ' . join(', ', @missing));

my @extra = grep { !$by_shape{$_} } sort @declared;
is(scalar(@extra), 0, 'cases.txt lists every shape bench.lua defines')
    or diag('missing from cases.txt: ' . join(', ', @extra));

# the axes the plan asks the matrix to cover
for my $shape (qw(oneshot stateful stream short post tls dns chunked trailers
                  hdr40 cookies req30)) {
    ok($by_shape{$shape}, "matrix covers the $shape axis");
}

ok(-f $target_template, 'target nginx template exists');
ok(-f $upstream_template, 'upstream nginx template exists');
ok(-f $wrk_headers, 'wrk headers script exists');
like(slurp($readme), qr/\| `WRK_CONNECTIONS` \| `100` \|/,
    'README documents wrk2 connection default');
like(slurp($readme), qr/\| `KEEPALIVE_POOL_SIZE` \| `120` \|/,
    'README documents keepalive pool default');

# A dedicated RUN_DIR, because prepare_configs starts by rm -rf'ing it. Sharing
# the default with a real run would let this test delete a live benchmark's
# prefix out from under it, taking the pid files with it so the runner could no
# longer even stop its own nginx.
my $dry_run_dir = File::Spec->catdir($root, 'benchmark', '.run-dryrun');

my $cmd = join ' ',
    'cd', quotemeta($root), '&&',
    "RUN_DIR=" . quotemeta($dry_run_dir),
    'BENCH_DRY_RUN=1',
    'TARGET_CPU=0',
    'UPSTREAM_CPUS=1',
    'WRK_CPUS=1',
    'WRK_THREADS=1',
    'WRK_CONNECTIONS=1',
    'WRK_DURATION=1s',
    'WRK_RATE=1000',
    'make bench';

my $output = `$cmd 2>&1`;
my $exit = $? >> 8;
is($exit, 0, 'make bench dry-run exits successfully') or diag($output);
like($output, qr/Benchmark configuration/, 'dry-run prints configuration');
like($output, qr/TARGET_CPU=0/, 'dry-run prints target CPU');
like($output, qr/UPSTREAM_CPUS=1/, 'dry-run prints upstream CPUs');
like($output, qr/WRK_CPUS=1/, 'dry-run prints wrk CPUs');
like($output, qr/KEEPALIVE_POOL_SIZE=120/, 'dry-run prints keepalive pool default');
like($output, qr/WRK_RATE=1000/, 'dry-run prints wrk2 target rate');
like($output, qr/BENCH_REPEATS=5/, 'dry-run prints the repeat count');

my $rendered_target = File::Spec->catfile(
    $dry_run_dir, 'target', 'conf', 'nginx.conf'
);
my $rendered_upstream = File::Spec->catfile(
    $dry_run_dir, 'upstream', 'conf', 'nginx.conf'
);
my $rendered_locations = File::Spec->catfile(
    $dry_run_dir, 'target', 'conf', 'bench_locations.conf'
);

ok(-f $rendered_target, 'dry-run renders target nginx config');
ok(-f $rendered_upstream, 'dry-run renders upstream nginx config');
ok(-f $rendered_locations, 'dry-run generates the bench locations');

my $target_conf = slurp($rendered_target);
like($target_conf, qr/location = \/bench\/baseline/, 'target config has baseline benchmark endpoint');
like($target_conf, qr/include bench_locations\.conf;/, 'target config includes the generated locations');
like($target_conf, qr/worker_processes 1;/, 'target config uses one worker');
unlike($target_conf, qr/\{\{[A-Z_]+\}\}/, 'target config has no unrendered placeholders');

my $locations = slurp($rendered_locations);
for my $name (@cases) {
    like($locations, qr/location = \/bench\/\Q$name\E \{/,
        "generated locations include /bench/$name");
}
like($locations, qr/location = \/echo\/ffi\.stateful \{/,
    'generated locations include the fairness-audit echo endpoints');

my $upstream_conf = slurp($rendered_upstream);
like($upstream_conf, qr/Content-Length/, 'upstream config returns content-length response');
like($upstream_conf, qr/benchmark_response_body/, 'upstream config prebuilds response body');
like($upstream_conf, qr/location = \/mock\/chunked/, 'upstream serves a chunked response');
like($upstream_conf, qr/location = \/mock\/echo/, 'upstream echoes the raw request headers');
like($upstream_conf, qr/location = \/mock\/sink/, 'upstream accepts a request body');
like($upstream_conf, qr/location = \/mock\/headers40/, 'upstream serves a header-heavy response');
like($upstream_conf, qr/location = \/mock\/cookies/, 'upstream serves repeated Set-Cookie headers');
like($upstream_conf, qr/^stream \{/m, 'upstream runs a raw TCP mock for trailers');
like($upstream_conf, qr/X-Checksum/, 'raw TCP mock sends a trailer');
unlike($upstream_conf, qr/\{\{[A-Z_]+\}\}/, 'upstream config has no unrendered placeholders');

done_testing();
