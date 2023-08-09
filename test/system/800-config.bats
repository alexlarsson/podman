#!/usr/bin/env bats   -*- bats -*-
#
# Test specific configuration options and overrides
#

load helpers

@test "podman CONTAINERS_CONF - CONTAINERS_CONF in conmon" {
    skip_if_remote "can't check conmon environment over remote"

    # Get the normal runtime for this host
    run_podman info --format '{{ .Host.OCIRuntime.Name }}'
    runtime="$output"
    run_podman info --format "{{ .Host.OCIRuntime.Path }}"
    ocipath="$output"
    run_podman info --format '{{ .Host.DatabaseBackend }}'
    db_backend="$output"

    # Make an innocuous containers.conf in a non-standard location
    conf_tmp="$PODMAN_TMPDIR/containers.conf"
    cat >$conf_tmp <<EOF
[engine]
runtime="$runtime"
database_backend="$db_backend"
[engine.runtimes]
$runtime = ["$ocipath"]
EOF
    CONTAINERS_CONF="$conf_tmp" run_podman run -d $IMAGE sleep infinity
    cid="$output"

    CONTAINERS_CONF="$conf_tmp" run_podman inspect "$cid" --format "{{ .State.ConmonPid }}"
    conmon="$output"

    output="$(tr '\0' '\n' < /proc/$conmon/environ | grep '^CONTAINERS_CONF=')"
    is "$output" "CONTAINERS_CONF=$conf_tmp"

    # Clean up
    # Oddly, sleep can't be interrupted with SIGTERM, so we need the
    # "-f -t 0" to force a SIGKILL
    CONTAINERS_CONF="$conf_tmp" run_podman rm -f -t 0 "$cid"
}

@test "podman CONTAINERS_CONF - override runtime name" {
    skip_if_remote "Can't set CONTAINERS_CONF over remote"

    # Get the path of the normal runtime
    run_podman info --format "{{ .Host.OCIRuntime.Path }}"
    ocipath="$output"
    run_podman info --format '{{ .Host.DatabaseBackend }}'
    db_backend="$output"

    export conf_tmp="$PODMAN_TMPDIR/nonstandard_runtime_name.conf"
    cat > $conf_tmp <<EOF
[engine]
runtime = "nonstandard_runtime_name"
database_backend="$db_backend"
[engine.runtimes]
nonstandard_runtime_name = ["$ocipath"]
EOF

    CONTAINERS_CONF="$conf_tmp" run_podman run -d --rm $IMAGE true
    cid="$output"

    # We need to wait for the container to finish before we can check
    # if it was cleaned up properly.  But in the common case that the
    # container completes fast, and the cleanup *did* happen properly
    # the container is now gone.  So, we need to ignore "no such
    # container" errors from podman wait.
    CONTAINERS_CONF="$conf_tmp" run_podman '?' wait "$cid"
    if [[ $status != 0 ]]; then
        is "$output" "Error:.*no such container" "unexpected error from podman wait"
    fi

    # The --rm option means the container should no longer exist.
    # However https://github.com/containers/podman/issues/12917 meant
    # that the container cleanup triggered by conmon's --exit-cmd
    # could fail, leaving the container in place.
    #
    # We verify that the container is indeed gone, by checking that a
    # podman rm *fails* here - and it has the side effect of cleaning
    # up in the case this test fails.
    CONTAINERS_CONF="$conf_tmp" run_podman 1 rm "$cid"
    is "$output" "Error:.*no such container"
}

@test "podman --module - absolute path" {
    skip_if_remote "--module is not supported for remote clients"

    random_data="expected_annotation_$(random_string 15)"
    conf_tmp="$PODMAN_TMPDIR/test.conf"
    cat > $conf_tmp <<EOF
[containers]
annotations=['module=$random_data']
EOF

    run_podman --module=$conf_tmp create -q $IMAGE
    cid="$output"
    run_podman container inspect $cid --format '{{index .Config.Annotations "module"}}'
    is "$output" "$random_data" "container annotation should include the one from the --module"

    run_podman rm -f $cid

    # Nonexistent module path
    nonesuch=${PODMAN_TMPDIR}/nonexistent
    run_podman 1 --module=$nonesuch sdfsdfdsf
    is "$output" "Failed to obtain podman configuration: could not resolve module \"$nonesuch\": stat $nonesuch: no such file or directory" \
       "--module=ENOENT"
}

@test "podman --module - XDG_CONFIG_HOME" {
    skip_if_remote "--module is not supported for remote clients"
    skip_if_not_rootless "loading a module from XDG_CONFIG_HOME requires rootless"

    fake_home="$PODMAN_TMPDIR/home/.config"
    fake_modules_dir="$fake_home/containers/containers.conf.modules"
    mkdir -p $fake_modules_dir

    random_data="expected_annotation_$(random_string 15)"
    module_name="test.conf"
    conf_tmp="$fake_modules_dir/$module_name"
    cat > $conf_tmp <<EOF
[containers]
annotations=['module=$random_data']
EOF

    # Test loading a relative path (test.conf) as a module.  This should find
    # the one in the fake XDG_CONFIG_HOME.  We cannot override /etc or
    # /usr/share in the tests here, so for those paths we need to rely on the
    # unit tests in containers/common/pkg/config and manual QE.
    XDG_CONFIG_HOME=$fake_home run_podman --module $module_name run -d -q $IMAGE sleep infinity
    cid="$output"
    run_podman container inspect $cid --format '{{index .Config.Annotations "module"}}'
    is "$output" "$random_data" "container annotation should include the one from the --module"

    # Now make sure that conmon's exit-command points to the _absolute path_ of
    # the module.
    run_podman container inspect $cid --format "{{ .State.ConmonPid }}"
    conmon_pid="$output"
    is "$(< /proc/$conmon_pid/cmdline)" ".*--exit-command-arg--module--exit-command-arg$conf_tmp.*" "conmon's exit-command uses the module"
    run_podman rm -f -t0 $cid

    # Corrupt module file
    cat > $conf_tmp <<EOF
[containers]
sdf=
EOF
    XDG_CONFIG_HOME=$fake_home run_podman 1 --module $module_name
    is "$output" "Failed to obtain podman configuration: reading additional config \"$conf_tmp\": decode configuration $conf_tmp: toml: line 3 (last key \"containers.sdf\"): expected value but found '\n' instead" \
       "Corrupt module file"

    # Nonexistent module name
    nonesuch=assume-this-does-not-exist-$(random_string)
    XDG_CONFIG_HOME=$fake_home run_podman 1 --module=$nonesuch invalid-command
    expect="Failed to obtain podman configuration: could not resolve module \"$nonesuch\": 3 errors occurred:"
    for dir in $fake_home /etc /usr/share;do
        expect+=$'\n\t'"* stat $dir/containers/containers.conf.modules/$nonesuch: no such file or directory"
    done
    is "$output" "$expect" "--module=ENOENT : error message"
}

# Too hard to test in 600-completion.bats because of the remote/rootless check
@test "podman --module - command-line completion" {
    skip_if_remote "--module is not supported for remote clients"
    skip_if_not_rootless "loading a module from XDG_CONFIG_HOME requires rootless"

    fake_home="$PODMAN_TMPDIR/home/.config"
    fake_modules_dir="$fake_home/containers/containers.conf.modules"
    mkdir -p $fake_modules_dir

    m1=m1odule_$(random_string)
    m2=m2$(random_string)

    touch $fake_modules_dir/{$m2,$m1}
    XDG_CONFIG_HOME=$fake_home run_podman __completeNoDesc --module ""
    # Even if there are modules in /etc or elsewhere, these will be first
    assert "${lines[0]}" = "$m1" "completion finds module 1"
    assert "${lines[1]}" = "$m2" "completion finds module 2"
}

# vim: filetype=sh
