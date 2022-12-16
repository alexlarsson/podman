#!/usr/bin/env bats   -*- bats -*-
#
# Tests generated configurations for systemd.
#

load helpers
load helpers.systemd

UNIT_FILES=()

function start_time() {
    sleep_to_next_second # Ensure we're on a new second with no previous logging
    STARTED_TIME=$(date "+%F %R:%S") # Start time for new log time
}

function setup() {
    skip_if_remote "quadlet tests are meaningless over remote"

    start_time

    basic_setup
}

function teardown() {
    for UNIT_FILE in ${UNIT_FILES[@]}; do
        if [[ -e "$UNIT_FILE" ]]; then
            local service=$(basename "$UNIT_FILE")
            run systemctl stop "$service"
            if [ $status -ne 0 ]; then
               echo "# WARNING: systemctl stop failed in teardown: $output" >&3
            fi
            rm -f "$UNIT_FILE"
        fi
    done
    systemctl daemon-reload

    basic_teardown
}

# Converts the quadlet file and installs the result it in $UNIT_DIR
function run_quadlet() {
    local sourcefile="$1"
    local service=$(quadlet_to_service_name "$sourcefile")

    # quadlet always works on an entire directory, so copy the file
    # to transform to a tmpdir
    local quadlet_tmpdir=$(mktemp -d --tmpdir=$PODMAN_TMPDIR quadlet.XXXXXX)
    cp $sourcefile $quadlet_tmpdir/

    QUADLET_UNIT_DIRS="$quadlet_tmpdir" run $QUADLET $_DASHUSER $UNIT_DIR
    assert $status -eq 0 "Failed to convert quadlet file: $sourcefile"
    is "$output" "" "quadlet should report no errors"

    # Ensure this is teared down
    UNIT_FILES+=("$UNIT_DIR/$service")

    QUADLET_SERVICE_NAME="$service"
    QUADLET_CONTAINER_NAME="systemd-$(basename $service .service)"

    cat $UNIT_DIR/$QUADLET_SERVICE_NAME
}

function service_setup() {
    local service="$1"
    local option="$2"

    systemctl daemon-reload

    local startargs=""
    local statusexit=0
    local activestate="active"

    # If option wait, start and wait for service to exist
    if [ "$option" == "wait" ]; then
	startargs="--wait"
	statusexit=3
	local activestate="inactive"
    fi

    run systemctl $startargs start "$service"
    assert $status -eq 0 "Error starting systemd unit $service: $output"

    run systemctl status "$service"
    assert $status -eq $statusexit "systemctl status $service: $output"

    run systemctl show -P ActiveState "$service"
    assert $status -eq 0 "systemctl show $service: $output"
    is "$output" $activestate
}

# Helper to stop a systemd service running a container
function service_cleanup() {
    local service="$1"
    local expected_state="$2"

    run systemctl stop "$service"
    assert $status -eq 0 "Error stopping systemd unit $service: $output"

    # Regression test for #11304: confirm that unit stops into correct state
    if [[ -n "$expected_state" ]]; then
        run systemctl show --property=ActiveState "$service"
        assert "$output" = "ActiveState=$expected_state" \
               "state of service after systemctl stop"
    fi

    rm -f "$UNIT_DIR/$service"
    systemctl daemon-reload
}

@test "quadlet - basic" {
    local quadlet_file=$PODMAN_TMPDIR/basic_$(random_string).container
    cat > $quadlet_file <<EOF
[Container]
Image=$IMAGE
Exec=sh -c "echo STARTED CONTAINER; echo "READY=1" | socat -u STDIN unix-sendto:\$NOTIFY_SOCKET; top"
Notify=yes
EOF

    run_quadlet "$quadlet_file"
    service_setup $QUADLET_SERVICE_NAME

    # Ensure we have output. Output is synced via sd-notify (socat in Exec)
    run journalctl "--since=$STARTED_TIME" --unit="$QUADLET_SERVICE_NAME"
    is "$output" '.*STARTED CONTAINER.*'

    run_podman container inspect  --format "{{.State.Status}}" $QUADLET_CONTAINER_NAME
    is "$output" "running" "container should be started by systemd and hence be running"

    service_cleanup $QUADLET_SERVICE_NAME failed
}

@test "quadlet - envvar" {
    local quadlet_file=$PODMAN_TMPDIR/envvar_$(random_string).container
    cat > $quadlet_file <<EOF
[Container]
Image=$IMAGE
Exec=sh -c "echo OUTPUT: \"\$FOOBAR\" \"\$BAR\""
Environment="FOOBAR=Foo  Bar" BAR=bar
EOF

    run_quadlet "$quadlet_file"
    service_setup $QUADLET_SERVICE_NAME wait

    # Ensure we have the right output, sync is done via waiting for service to exit (service_setup wait)
    run journalctl "--since=$STARTED_TIME" --unit="$QUADLET_SERVICE_NAME"
    is "$output" '.*OUTPUT: Foo  Bar bar.*'
    
    service_cleanup $QUADLET_SERVICE_NAME inactive
}

@test "quadlet - ContainerName" {
    local quadlet_file=$PODMAN_TMPDIR/containername_$(random_string).container
    cat > $quadlet_file <<EOF
[Container]
ContainerName=customcontainername
Image=$IMAGE
Exec=top"
EOF

    run_quadlet "$quadlet_file"
    service_setup $QUADLET_SERVICE_NAME

    # Ensure we can access with the custom container name
    run_podman container inspect  --format "{{.State.Status}}" customcontainername
    is "$output" "running" "container should be started by systemd and hence be running"

    service_cleanup $QUADLET_SERVICE_NAME failed
}

@test "quadlet - labels" {
    local quadlet_file=$PODMAN_TMPDIR/labels_$(random_string).container
    cat > $quadlet_file <<EOF
[Container]
Image=$IMAGE
Exec=top
Label="foo=foo bar" "key=val"
Annotation="afoo=afoo bar"
Annotation="akey=aval"
EOF

    run_quadlet "$quadlet_file"
    service_setup $QUADLET_SERVICE_NAME

    run_podman container inspect --format "{{.Config.Labels.foo}}" $QUADLET_CONTAINER_NAME
    is "$output" "foo bar"
    run_podman container inspect --format "{{.Config.Labels.key}}" $QUADLET_CONTAINER_NAME
    is "$output" "val"
    run_podman container inspect --format "{{.Config.Annotations.afoo}}" $QUADLET_CONTAINER_NAME
    is "$output" "afoo bar"
    run_podman container inspect --format "{{.Config.Annotations.akey}}" $QUADLET_CONTAINER_NAME
    is "$output" "aval"

    service_cleanup $QUADLET_SERVICE_NAME failed
}

@test "quadlet - volume" {
    local quadlet_file=$PODMAN_TMPDIR/basic_$(random_string).volume
    cat > $quadlet_file <<EOF
[Volume]
Label=foo=bar other="with space"
EOF

    run_quadlet "$quadlet_file"

    service_setup $QUADLET_SERVICE_NAME

    local volume_name=systemd-$(basename $quadlet_file .volume)
    run_podman volume ls
    is "$output" ".*local.*${volume_name}.*"

    run_podman volume inspect  --format "{{.Labels.foo}}" $volume_name
    is "$output" "bar"
    run_podman volume inspect  --format "{{.Labels.other}}" $volume_name
    is "$output" "with space"

    service_cleanup $QUADLET_SERVICE_NAME inactive
}

# A quadlet container depends on a quadlet volume
@test "quadlet - volume dependency" {
    local quadlet_vol_file=$PODMAN_TMPDIR/dep_$(random_string).volume
    cat > $quadlet_vol_file <<EOF
[Volume]
EOF

    run_quadlet "$quadlet_vol_file"

    local vol_service=$QUADLET_SERVICE_NAME
    local volume_name=systemd-$(basename $quadlet_vol_file .volume)

    local quadlet_file=$PODMAN_TMPDIR/user_$(random_string).container
    cat > $quadlet_file <<EOF
[Container]
Image=$IMAGE
Exec=top
Volume=$vol_service:/tmp
EOF

    # Volume should not exist
    run_podman volume ls
    assert "$output" !~ ".*${volume_name}.*"

    service_setup $QUADLET_SERVICE_NAME

    # Volume system unit should be active
    run systemctl show --property=ActiveState "$vol_service"
    assert "$output" = "ActiveState=active" \
           "volume should be active via dependency"

    # Volume should exist
    volume_name=systemd-$(basename $quadlet_vol_file .volume)
    run_podman volume ls
    is "$output" ".*local.*${volume_name}.*"

    service_cleanup $QUADLET_SERVICE_NAME inactive
}

# vim: filetype=sh
