#!/usr/bin/env nu
# run.nu — dependency-free unit-test runner for the enterpriseclaw CLI.
#
# Usage (inside Devbox, from cli/):  nu tests/run.nu
# Discovers each suite, runs every test closure under try/catch, prints pass/fail, exits non-zero
# if anything failed. Cluster-free: only the pure generators + file-generation logic are exercised.

source app-of-apps.test.nu
source broker-exposure.test.nu

def main [] {
    let suites = [
        { name: "app-of-apps", tests: (app-of-apps-tests) }
        { name: "broker-exposure", tests: (broker-exposure-tests) }
    ]

    mut total = 0
    mut failed = 0
    for suite in $suites {
        print $"(ansi cyan_bold)# ($suite.name)(ansi reset)"
        for t in $suite.tests {
            $total = $total + 1
            let r = (try { do $t.run; { ok: true, err: "" } } catch { |e| { ok: false, err: $e.msg } })
            if $r.ok {
                print $"  (ansi green)✓(ansi reset) ($t.name)"
            } else {
                $failed = $failed + 1
                print $"  (ansi red)✗ ($t.name)(ansi reset)"
                print $"      (ansi red)($r.err)(ansi reset)"
            }
        }
    }

    print ""
    let passed = ($total - $failed)
    if $failed > 0 {
        print $"(ansi red_bold)($passed)/($total) passed — ($failed) FAILED(ansi reset)"
        exit 1
    } else {
        print $"(ansi green_bold)($passed)/($total) passed(ansi reset)"
    }
}
