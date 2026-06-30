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
my $target_template = File::Spec->catfile($root, 'benchmark', 'conf', 'target.nginx.conf');
my $upstream_template = File::Spec->catfile($root, 'benchmark', 'conf', 'upstream.nginx.conf');
my $wrk_headers = File::Spec->catfile($root, 'benchmark', 'wrk', 'headers.lua');

ok(-f $makefile, 'Makefile exists');
like(slurp($makefile), qr/^bench:\s*$/m, 'Makefile defines bench target');
like(slurp($makefile), qr{\./benchmark/run\.sh}, 'bench target delegates to benchmark/run.sh');

ok(-x $runner, 'benchmark/run.sh exists and is executable');
like(slurp($runner), qr/BENCH_DRY_RUN/, 'runner supports dry-run mode');
like(slurp($runner), qr/CPU_SATURATION_THRESHOLD/, 'runner checks CPU saturation');
like(slurp($runner), qr/WRK2_BIN/, 'runner uses wrk2 binary configuration');
like(slurp($runner), qr/WRK_RATE/, 'runner supports wrk2 target rate');
like(slurp($runner), qr/\s-U\s/, 'runner enables wrk2 uncorrected latency output');
like(slurp($runner), qr/\s-R\s+"\$WRK_RATE"/, 'runner passes wrk2 target rate');

ok(-f $target_template, 'target nginx template exists');
ok(-f $upstream_template, 'upstream nginx template exists');
ok(-f $wrk_headers, 'wrk headers script exists');

my $cmd = join ' ',
    'cd', quotemeta($root), '&&',
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
like($output, qr/WRK_RATE=1000/, 'dry-run prints wrk2 target rate');

my $rendered_target = File::Spec->catfile(
    $root, 'benchmark', '.run', 'target', 'conf', 'nginx.conf'
);
my $rendered_upstream = File::Spec->catfile(
    $root, 'benchmark', '.run', 'upstream', 'conf', 'nginx.conf'
);

ok(-f $rendered_target, 'dry-run renders target nginx config');
ok(-f $rendered_upstream, 'dry-run renders upstream nginx config');

my $target_conf = slurp($rendered_target);
like($target_conf, qr/location = \/bench\/ffi/, 'target config has C FFI benchmark endpoint');
like($target_conf, qr/location = \/bench\/resty-http/, 'target config has resty.http benchmark endpoint');
like($target_conf, qr/worker_processes 1;/, 'target config uses one worker');

my $upstream_conf = slurp($rendered_upstream);
like($upstream_conf, qr/Content-Length/, 'upstream config returns content-length response');
like($upstream_conf, qr/benchmark_response_body/, 'upstream config prebuilds response body');

done_testing();
