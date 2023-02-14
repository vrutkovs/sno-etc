#!/bin/bash
set -eux
# This file is not needed anymore in 4.7+, but when rolling back to 4.6
# the ovs pod needs it to know ovs is running on the host.
touch /var/run/ovs-config-executed

# These are well knwon NM default paths
NM_CONN_ETC_PATH="/etc/NetworkManager/system-connections"
NM_CONN_RUN_PATH="/run/NetworkManager/system-connections"

# This is the path where NM is known to be configured to store user keyfiles 
NM_CONN_CONF_PATH="$NM_CONN_ETC_PATH"
# This is where we want our keyfiles to finally reside
NM_CONN_SET_PATH="${NM_CONN_SET_PATH:-$NM_CONN_RUN_PATH}"

# this flag tracks if any config change was made
nm_config_changed=0

MANAGED_NM_CONN_SUFFIX="-slave-ovs-clone"
# Workaround to ensure OVS is installed due to bug in systemd Requires:
# https://bugzilla.redhat.com/show_bug.cgi?id=1888017
copy_nm_conn_files() {
  local dst_path="$1"
  for src in "${MANAGED_NM_CONN_FILES[@]}"; do
    src_path=$(dirname "$src")
    file=$(basename "$src")
    if [ -f "$src_path/$file" ]; then
      if [ ! -f "$dst_path/$file" ]; then
        echo "Copying configuration $file"
        cp "$src_path/$file" "$dst_path/$file"
      elif ! cmp --silent "$src_path/$file" "$dst_path/$file"; then
        echo "Copying updated configuration $file"
        cp -f "$src_path/$file" "$dst_path/$file"
      else
        echo "Skipping $file since it's equal at destination"
      fi
    else
      echo "Skipping $file since it does not exist at source"
    fi
  done
}

update_nm_conn_files_base() {
  base_path=${1}
  bridge_name=${2}
  port_name=${3}
  ovs_port="ovs-port-${bridge_name}"
  ovs_interface="ovs-if-${bridge_name}"
  default_port_name="ovs-port-${port_name}" # ovs-port-phys0
  bridge_interface_name="ovs-if-${port_name}" # ovs-if-phys0
  # In RHEL7 files in /{etc,run}/NetworkManager/system-connections end without the suffix '.nmconnection', whereas in RHCOS they end with the suffix.
  MANAGED_NM_CONN_FILES=($(echo "${base_path}"/{"$bridge_name","$ovs_interface","$ovs_port","$bridge_interface_name","$default_port_name"}{,.nmconnection}))
  shopt -s nullglob
  MANAGED_NM_CONN_FILES+=(${base_path}/*${MANAGED_NM_CONN_SUFFIX}.nmconnection ${base_path}/*${MANAGED_NM_CONN_SUFFIX})
  shopt -u nullglob
}

update_nm_conn_conf_files() {
  update_nm_conn_files_base "${NM_CONN_CONF_PATH}" "${1}" "${2}"
}

update_nm_conn_set_files() {
  update_nm_conn_files_base "${NM_CONN_SET_PATH}" "${1}" "${2}"
}

# Move and reload keyfiles at their final destination
set_nm_conn_files() {
  if [ "$NM_CONN_CONF_PATH" != "$NM_CONN_SET_PATH" ]; then
    update_nm_conn_conf_files br-ex phys0
    copy_nm_conn_files "$NM_CONN_SET_PATH"
    rm_nm_conn_files
    update_nm_conn_conf_files br-ex1 phys1
    copy_nm_conn_files "$NM_CONN_SET_PATH"
    rm_nm_conn_files

    # reload keyfiles
    nmcli connection reload
  fi
}

# Used to remove files managed by configure-ovs
rm_nm_conn_files() {
  for file in "${MANAGED_NM_CONN_FILES[@]}"; do
    if [ -f "$file" ]; then
      rm -f "$file"
      echo "Removed nmconnection file $file"
      nm_config_changed=1
    fi
  done
}

# Used to clone a slave connection by uuid, returns new uuid
clone_slave_connection() {
  local uuid="$1"
  local old_name
  old_name="$(nmcli -g connection.id connection show uuid "$uuid")"
  local new_name="${old_name}${MANAGED_NM_CONN_SUFFIX}"
  if nmcli connection show id "${new_name}" &> /dev/null; then
    echo "WARN: existing ovs slave ${new_name} connection profile file found, overwriting..." >&2
    nmcli connection delete id "${new_name}" &> /dev/null
  fi
  nmcli connection clone $uuid "${new_name}" &> /dev/null
  nmcli -g connection.uuid connection show "${new_name}"
}

# Used to replace an old master connection uuid with a new one on all connections
replace_connection_master() {
  local old="$1"
  local new="$2"
  for conn_uuid in $(nmcli -g UUID connection show) ; do
    if [ "$(nmcli -g connection.master connection show uuid "$conn_uuid")" != "$old" ]; then
      continue
    fi

    local active_state=$(nmcli -g GENERAL.STATE connection show "$conn_uuid")
    local autoconnect=$(nmcli -g connection.autoconnect connection show "$conn_uuid")
    if [ "$active_state" != "activated" ] && [ "$autoconnect" != "yes" ]; then
      # Assume that slave profiles intended to be used are those that are:
      # - active
      # - or inactive (which might be due to link being down) but to be autoconnected.
      # Otherwise, ignore them.
      continue
    fi

    # make changes for slave profiles in a new clone
    local new_uuid
    new_uuid=$(clone_slave_connection $conn_uuid)

    nmcli conn mod uuid $new_uuid connection.master "$new"
    nmcli conn mod $new_uuid connection.autoconnect-priority 100
    nmcli conn mod $new_uuid connection.autoconnect no
    echo "Replaced master $old with $new for slave profile $new_uuid"
  done
}

# when creating the bridge, we use a value lower than NM's ethernet device default route metric
# (we pick 48 and 49 to be lower than anything that NM chooses by default)
BRIDGE_METRIC="48"
BRIDGE1_METRIC="49"
# Given an interface, generates NM configuration to add to an OVS bridge
convert_to_bridge() {
  local iface=${1}
  local bridge_name=${2}
  local port_name=${3}
  local bridge_metric=${4}
  local ovs_port="ovs-port-${bridge_name}"
  local ovs_interface="ovs-if-${bridge_name}"
  local default_port_name="ovs-port-${port_name}" # ovs-port-phys0
  local bridge_interface_name="ovs-if-${port_name}" # ovs-if-phys0

  if [ "$iface" = "$bridge_name" ]; then
    # handle vlans and bonds etc if they have already been
    # configured via nm key files and br-ex is already up
    ifaces=$(ovs-vsctl list-ifaces ${iface})
    for intf in $ifaces; do configure_driver_options $intf; done
    echo "Networking already configured and up for ${bridge-name}!"
    return
  fi

  # flag to reload NM to account for all the configuration changes
  # going forward
  nm_config_changed=1

  if [ -z "$iface" ]; then
    echo "ERROR: Unable to find default gateway interface"
    exit 1
  fi
  # find the MAC from OVS config or the default interface to use for OVS internal port
  # this prevents us from getting a different DHCP lease and dropping connection
  if ! iface_mac=$(<"/sys/class/net/${iface}/address"); then
    echo "Unable to determine default interface MAC"
    exit 1
  fi

  echo "MAC address found for iface: ${iface}: ${iface_mac}"

  # find MTU from original iface
  iface_mtu=$(ip link show "$iface" | awk '{print $5; exit}')
  if [[ -z "$iface_mtu" ]]; then
    echo "Unable to determine default interface MTU, defaulting to 1500"
    iface_mtu=1500
  else
    echo "MTU found for iface: ${iface}: ${iface_mtu}"
  fi

  # store old conn for later
  old_conn=$(nmcli --fields UUID,DEVICE conn show --active | awk "/\s${iface}\s*\$/ {print \$1}")

  # create bridge
  if ! nmcli connection show "$bridge_name" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists del-br "$bridge_name"
    add_nm_conn type ovs-bridge con-name "$bridge_name" conn.interface "$bridge_name" 802-3-ethernet.mtu ${iface_mtu} \
    connection.autoconnect-slaves 1
  fi

  # find default port to add to bridge
  if ! nmcli connection show "$default_port_name" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists del-port "$bridge_name" ${iface}
    add_nm_conn type ovs-port conn.interface ${iface} master "$bridge_name" con-name "$default_port_name" \
    connection.autoconnect-slaves 1
  fi

  if ! nmcli connection show "$ovs_port" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists del-port "$bridge_name" "$bridge_name"
    add_nm_conn type ovs-port conn.interface "$bridge_name" master "$bridge_name" con-name "$ovs_port"
  fi

  extra_phys_args=()
  # check if this interface is a vlan, bond, team, or ethernet type
  if [ "$(nmcli --get-values connection.type conn show ${old_conn})" == "vlan" ]; then
    iface_type=vlan
    vlan_id=$(nmcli --get-values vlan.id conn show ${old_conn})
    if [ -z "$vlan_id" ]; then
      echo "ERROR: unable to determine vlan_id for vlan connection: ${old_conn}"
      exit 1
    fi
    vlan_parent=$(nmcli --get-values vlan.parent conn show ${old_conn})
    if [ -z "$vlan_parent" ]; then
      echo "ERROR: unable to determine vlan_parent for vlan connection: ${old_conn}"
      exit 1
    fi
    extra_phys_args=( dev "${vlan_parent}" id "${vlan_id}" )
  elif [ "$(nmcli --get-values connection.type conn show ${old_conn})" == "bond" ]; then
    iface_type=bond
    # check bond options
    bond_opts=$(nmcli --get-values bond.options conn show ${old_conn})
    if [ -n "$bond_opts" ]; then
      extra_phys_args+=( bond.options "${bond_opts}" )
      MODE_REGEX="(^|,)mode=active-backup(,|$)"
      MAC_REGEX="(^|,)fail_over_mac=(1|active|2|follow)(,|$)"
      if [[ $bond_opts =~ $MODE_REGEX ]] && [[ $bond_opts =~ $MAC_REGEX ]]; then
        clone_mac=0
      fi
    fi
  elif [ "$(nmcli --get-values connection.type conn show ${old_conn})" == "team" ]; then
    iface_type=team
    # check team config options
    team_config_opts=$(nmcli --get-values team.config -e no conn show ${old_conn})
    if [ -n "$team_config_opts" ]; then
      # team.config is json, remove spaces to avoid problems later on
      extra_phys_args+=( team.config "${team_config_opts//[[:space:]]/}" )
      team_mode=$(echo "${team_config_opts}" | jq -r ".runner.name // empty")
      team_mac_policy=$(echo "${team_config_opts}" | jq -r ".runner.hwaddr_policy // empty")
      MAC_REGEX="(by_active|only_active)"
      if [ "$team_mode" = "activebackup" ] && [[ "$team_mac_policy" =~ $MAC_REGEX ]]; then
        clone_mac=0
      fi
    fi
  else
    iface_type=802-3-ethernet
  fi

  if [ ! "${clone_mac:-}" = "0" ]; then
    # In active-backup link aggregation, with fail_over_mac mode enabled,
    # cloning the mac address is not supported. It is possible then that
    # br-ex has a different mac address than the bond which might be
    # troublesome on some platforms where the nic won't accept packets with
    # a different destination mac. But nobody has complained so far so go on
    # with what we got. 
    
    # Do set it though for other link aggregation configurations where the
    # mac address would otherwise depend on enslave order for which we have
    # no control going forward.
    extra_phys_args+=( 802-3-ethernet.cloned-mac-address "${iface_mac}" )
  fi

  # use ${extra_phys_args[@]+"${extra_phys_args[@]}"} instead of ${extra_phys_args[@]} to be compatible with bash 4.2 in RHEL7.9
  if ! nmcli connection show "$bridge_interface_name" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists destroy interface ${iface}
    add_nm_conn type ${iface_type} conn.interface ${iface} master "$default_port_name" con-name "$bridge_interface_name" \
    connection.autoconnect-priority 100 connection.autoconnect-slaves 1 802-3-ethernet.mtu ${iface_mtu} \
    ${extra_phys_args[@]+"${extra_phys_args[@]}"}
  fi

  # Get the new connection uuids
  new_conn=$(nmcli -g connection.uuid conn show "$bridge_interface_name")
  ovs_port_conn=$(nmcli -g connection.uuid conn show "$ovs_port")

  # Update connections with master property set to use the new connection
  replace_connection_master $old_conn $new_conn
  replace_connection_master $iface $new_conn

  if ! nmcli connection show "$ovs_interface" &> /dev/null; then
    ovs-vsctl --timeout=30 --if-exists destroy interface "$bridge_name"
    if nmcli --fields ipv4.method,ipv6.method conn show $old_conn | grep manual; then
      echo "Static IP addressing detected on default gateway connection: ${old_conn}"
      # clone the old connection to get the address settings
      # prefer cloning vs copying the connection file to avoid problems with selinux
      nmcli conn clone "${old_conn}" "${ovs_interface}"
      shopt -s nullglob
      new_conn_files=(${NM_CONN_CONF_PATH}/"${ovs_interface}"*)
      shopt -u nullglob
      if [ ${#new_conn_files[@]} -ne 1 ] || [ ! -f "${new_conn_files[0]}" ]; then
        echo "ERROR: could not find ${ovs_interface} conn file after cloning from ${old_conn}"
        exit 1
      fi
      new_conn_file="${new_conn_files[0]}"

      # modify basic connection settings, some of which can't be modified through nmcli
      sed -i '/^multi-connect=.*$/d' ${new_conn_file}
      sed -i '/^autoconnect=.*$/d' ${new_conn_file}
      sed -i '/^\[connection\]$/a autoconnect=false' ${new_conn_file}
      sed -i '/^\[connection\]$/,/^\[/ s/^type=.*$/type=ovs-interface/' ${new_conn_file}
      sed -i '/^\[connection\]$/a slave-type=ovs-port' ${new_conn_file}
      sed -i '/^\[connection\]$/a master='"$ovs_port_conn" ${new_conn_file}
      cat <<EOF >> ${new_conn_file}
[ovs-interface]
type=internal
EOF

      # reload the connection and modify some more settings through nmcli
      nmcli c load ${new_conn_file}
      nmcli c mod "${ovs_interface}" conn.interface "$bridge_name" \
        802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac} \
        ipv4.route-metric "${bridge_metric}" ipv6.route-metric "${bridge_metric}"
      echo "Loaded new $ovs_interface connection file: ${new_conn_file}"
    else
      extra_if_brex_args=""
      # check if interface had ipv4/ipv6 addresses assigned
      num_ipv4_addrs=$(ip -j a show dev ${iface} | jq ".[0].addr_info | map(. | select(.family == \"inet\")) | length")
      if [ "$num_ipv4_addrs" -gt 0 ]; then
        extra_if_brex_args+="ipv4.may-fail no "
      fi

      # IPV6 should have at least a link local address. Check for more than 1 to see if there is an
      # assigned address.
      num_ip6_addrs=$(ip -j a show dev ${iface} | jq ".[0].addr_info | map(. | select(.family == \"inet6\" and .scope != \"link\")) | length")
      if [ "$num_ip6_addrs" -gt 0 ]; then
        extra_if_brex_args+="ipv6.may-fail no "
      fi

      # check for dhcp client ids
      dhcp_client_id=$(nmcli --get-values ipv4.dhcp-client-id conn show ${old_conn})
      if [ -n "$dhcp_client_id" ]; then
        extra_if_brex_args+="ipv4.dhcp-client-id ${dhcp_client_id} "
      fi

      dhcp6_client_id=$(nmcli --get-values ipv6.dhcp-duid conn show ${old_conn})
      if [ -n "$dhcp6_client_id" ]; then
        extra_if_brex_args+="ipv6.dhcp-duid ${dhcp6_client_id} "
      fi

      ipv6_addr_gen_mode=$(nmcli --get-values ipv6.addr-gen-mode conn show ${old_conn})
      if [ -n "$ipv6_addr_gen_mode" ]; then
        extra_if_brex_args+="ipv6.addr-gen-mode ${ipv6_addr_gen_mode} "
      fi

      add_nm_conn type ovs-interface slave-type ovs-port conn.interface "$bridge_name" master "$ovs_port_conn" con-name \
        "$ovs_interface" 802-3-ethernet.mtu ${iface_mtu} 802-3-ethernet.cloned-mac-address ${iface_mac} \
        ipv4.route-metric "${bridge_metric}" ipv6.route-metric "${bridge_metric}" ${extra_if_brex_args}
    fi
  fi

  configure_driver_options "${iface}"
}

# Used to remove a bridge
remove_ovn_bridges() {
  bridge_name=${1}
  port_name=${2}

  # Remove the keyfiles from known configuration paths
  update_nm_conn_conf_files ${bridge_name} ${port_name}
  rm_nm_conn_files
  update_nm_conn_set_files ${bridge_name} ${port_name}
  rm_nm_conn_files

  # NetworkManager will not remove ${bridge_name} if it has the patch port created by ovn-kubernetes
  # so remove explicitly
  ovs-vsctl --timeout=30 --if-exists del-br ${bridge_name}
}

# Removes any previous ovs configuration
remove_all_ovn_bridges() {
  echo "Reverting any previous OVS configuration"
  
  remove_ovn_bridges br-ex phys0
  if [ -d "/sys/class/net/br-ex1" ]; then
    remove_ovn_bridges br-ex1 phys1
  fi
  
  echo "OVS configuration successfully reverted"
}

# Reloads NM NetworkManager profiles if any configuration change was done.
# Accepts a list of devices that should be re-connect after reload.
reload_profiles_nm() {
  if [ $nm_config_changed -eq 0 ]; then
    # no config was changed, no need to reload
    return
  fi

  # reload profiles
  nmcli connection reload

  # precautionary sleep of 10s (default timeout of NM to bring down devices)
  sleep 10

  # After reload, devices that were already connected should connect again
  # if any profile is available. If no profile is available, a device can
  # remain disconnected and we have to explicitly connect it so that a
  # profile is generated. This can happen for physical devices but should
  # not happen for software devices as those always require a profile.
  for dev in $@; do
    # Only attempt to connect a disconnected device
    local connected_state=$(nmcli -g GENERAL.STATE device show "$dev" || echo "")
    if [[ "$connected_state" =~ "disconnected" ]]; then
      # keep track if a profile by the same name as the device existed 
      # before we attempt activation
      local named_profile_existed=$([ -f "${NM_CONN_CONF_PATH}/${dev}" ] || [ -f "${NM_CONN_CONF_PATH}/${dev}.nmconnection" ] && echo "yes")
      
      for i in {1..10}; do
          echo "Attempt $i to connect device $dev"
          nmcli device connect "$dev" && break
          sleep 5
      done

      # if a profile did not exist before but does now, it was generated
      # but we want it to be ephemeral, so move it back to /run
      if [ ! "$named_profile_existed" = "yes" ]; then
        MANAGED_NM_CONN_FILES=("${NM_CONN_CONF_PATH}/${dev}" "${NM_CONN_CONF_PATH}/${dev}.nmconnection")
        copy_nm_conn_files "${NM_CONN_RUN_PATH}"
        rm_nm_conn_files
        # reload profiles so that NM notices that some might have been moved
        nmcli connection reload
      fi
    fi

    echo "Waiting for interface $dev to activate..."
    if ! timeout 60 bash -c "while ! nmcli -g DEVICE,STATE c | grep "'"'"$dev":activated'"'"; do sleep 5; done"; then
      echo "Warning: $dev did not activate"
    fi
  done

  nm_config_changed=0
}

# Removes all configuration and reloads NM if necessary
rollback_nm() {
  phys0=$(get_bridge_physical_interface ovs-if-phys0)
  phys1=$(get_bridge_physical_interface ovs-if-phys1)
  
  # Revert changes made by /usr/local/bin/configure-ovs.sh during SDN migration.
  remove_all_ovn_bridges
  
  # reload profiles so that NM notices that some were removed
  reload_profiles_nm "$phys0" "$phys1"
}

# Add a deactivated connection profile
add_nm_conn() {
  nmcli c add "$@" connection.autoconnect no
}

# Activates an ordered set of NM connection profiles
activate_nm_connections() {
  local connections=("$@")

  # We want autoconnect set for our cloned slave profiles so that they are
  # used over the original profiles if implicitly re-activated with other
  # dependant profiles. Otherwise if a slave activates with an old profile,
  # the old master profile might activate as well, interfering and causing
  # further activations to fail.
  # Slave interfaces should already be active so setting autoconnect here
  # won't implicitly activate them but there is an edge case where a slave
  # might be inactive (link down for example) and in that case setting
  # autoconnect will cause an implicit activation. This is not necessarily a
  # problem and hopefully we can make sure everything is activated as we
  # want next.
  for conn in "${connections[@]}"; do
    local slave_type=$(nmcli -g connection.slave-type connection show "$conn")
    if [ "$slave_type" = "team" ] || [ "$slave_type" = "bond" ]; then
      nmcli c mod "$conn" connection.autoconnect yes
    fi
  done

  # Activate all connections and fail if activation fails
  # For slave connections - for as long as at least one slave that belongs to a bond/team
  # comes up, we should not fail
  declare -A master_interfaces
  for conn in "${connections[@]}"; do
    # Get the slave type
    local slave_type=$(nmcli -g connection.slave-type connection show "$conn")
    local is_slave=false
    if [ "$slave_type" = "team" ] || [ "$slave_type" = "bond" ]; then
      is_slave=true
    fi 

    # For slave interfaces, initialize the master interface to false if the key is not yet in the array
    local master_interface
    if $is_slave; then
      master_interface=$(nmcli -g connection.master connection show "$conn")
      if ! [[ -v "master_interfaces[$master_interface]" ]]; then
        master_interfaces["$master_interface"]=false
      fi
    fi

    # Do not activate interfaces that are already active
    # But set the entry in master_interfaces to true if this is a slave
    # Also set autoconnect to yes
    local active_state=$(nmcli -g GENERAL.STATE conn show "$conn")
    if [ "$active_state" == "activated" ]; then
      echo "Connection $conn already activated"
      if $is_slave; then
        master_interfaces[$master_interface]=true
      fi
      nmcli c mod "$conn" connection.autoconnect yes
      continue
    fi

    # Activate all interfaces that are not yet active
    for i in {1..10}; do
      echo "Attempt $i to bring up connection $conn"
      nmcli conn up "$conn" && s=0 && break || s=$?
      sleep 5
    done
    if [ $s -eq 0 ]; then
      echo "Brought up connection $conn successfully"
      if $is_slave; then
        master_interfaces["$master_interface"]=true
      fi
    elif ! $is_slave; then
      echo "ERROR: Cannot bring up connection $conn after $i attempts"
      return $s
    fi
    nmcli c mod "$conn" connection.autoconnect yes
  done
  # Check that all master interfaces report at least a single active slave
  # Note: associative arrays require an exclamation mark when looping
  for i in "${!master_interfaces[@]}"; do
    if ! ${master_interfaces["$i"]}; then
        echo "ERROR: Cannot bring up any slave interface for master interface: $i"
        return 1
    fi
  done
}

# Accepts parameters $iface_default_hint_file, $iface
# Writes content of $iface into $iface_default_hint_file
write_iface_default_hint() {
  local iface_default_hint_file="$1"
  local iface="$2"

  echo "${iface}" >| "${iface_default_hint_file}"
}

# Accepts parameters $iface_default_hint_file
# Returns the stored interface default hint if the hint is non-empty,
# not br-ex, not br-ex1 and if the interface can be found in /sys/class/net
get_iface_default_hint() {
  local iface_default_hint_file=$1
  if [ -f "${iface_default_hint_file}" ]; then
    local iface_default_hint=$(cat "${iface_default_hint_file}")
    if [ "${iface_default_hint}" != "" ] &&
       [ "${iface_default_hint}" != "br-ex" ] &&
       [ "${iface_default_hint}" != "br-ex1" ] &&
       [ -d "/sys/class/net/${iface_default_hint}" ]; then
       echo "${iface_default_hint}"
       return
    fi
  fi
  echo ""
}

get_ip_from_ip_hint_file() {
  local ip_hint_file="$1"
  if [[ ! -f "${ip_hint_file}" ]]; then
    return
  fi
  ip_hint=$(cat "${ip_hint_file}")
  echo "${ip_hint}"
}

# This function waits for ip address of br-ex to be bindable only in case of ipv6
# This is workaround for OCPBUGS-673 as it will not allow starting crio
# before address is bindable
try_to_bind_ipv6_address() {
  # Retry for 1 minute
  retries=60
  until [[ ${retries} -eq 0 ]]; do
    ip=$(ip -6 -j addr | jq -r "first(.[] | select(.ifname==\"br-ex\") | .addr_info[] | select(.scope==\"global\") | .local)")
    if [[ "${ip}" == "" ]]; then
      echo "No ipv6 ip to bind was found"
      break
    fi
    random_port=$(shuf -i 50000-60000 -n 1)
    echo "Trying to bind ${ip} on port ${random_port}"
    exit_code=$(timeout 2s nc -l "${ip}" ${random_port}; echo $?)
    if [[ exit_code -eq 124 ]]; then
      echo "Address bound successfully"
      break
    fi
    sleep 1
    (( retries-- ))
  done
  if [[ ${retries} -eq 0 ]]; then
    echo "Failed to bind ip"
    exit 1
  fi
}

# Get interface that matches ip from node ip hint file
# in case file not exists return nothing and
# fallback to default interface search flow
get_nodeip_hint_interface() {
  local ip_hint=""
  local ip_hint_file="$1"
  local extra_bridge="$2"
  local iface=""

  ip_hint=$(get_ip_from_ip_hint_file "${ip_hint_file}")
  if [[ -z "${ip_hint}"  ]]; then
    return
  fi

  iface=$(ip -j addr | jq -r "first(.[] | select(any(.addr_info[]; .local==\"${ip_hint}\") and .ifname!=\"br-ex1\" and .ifname!=\"${extra_bridge}\")) | .ifname")
  if [[ -n "${iface}" ]]; then
    echo "${iface}"
  fi
}

# Accepts parameters $bridge_interface (e.g. ovs-port-phys0)
# Returns the physical interface name if $bridge_interface exists, "" otherwise
get_bridge_physical_interface() {
  local bridge_interface="$1"
  local physical_interface=""
  physical_interface=$(nmcli -g connection.interface-name conn show "${bridge_interface}" 2>/dev/null || echo "")
  echo "${physical_interface}"
}

# Accepts parameters $iface, $iface_default_hint_file, $ip_hint_file
# Finds the nodeip interface from the interface that matches the ip address in $ip_hint_file.
# Otherwise fallbacks to a previously used interface or to the default interface.ç
# Never use the interface that is provided inside extra_bridge_file for br-ex1.
# Never use br-ex1.
# Read $ip_hint_file and return the interface that matches this ip.  Otherwise:
# If the default interface is br-ex, use that and return.
# If the default interface is not br-ex:
# Check if there is a valid hint inside iface_default_hint_file. If so, use that hint.
# If there is no valid hint, use the default interface that we found during the step
# earlier. Write the default interface to the hint file.
get_nodeip_interface() {
  local iface=""
  local counter=0
  local iface_default_hint_file="$1"
  local extra_bridge_file="$2"
  local ip_hint_file="$3"
  local extra_bridge=""

  if [ -f "${extra_bridge_file}" ]; then
    extra_bridge=$(cat ${extra_bridge_file})
  fi

  # if node ip was set, we should search for interface that matches it
  iface=$(get_nodeip_hint_interface "${ip_hint_file}" "${extra_bridge}")
  if [[ -n "${iface}" ]]; then
    echo "${iface}"
    return
  fi

  # find default interface
  # the default interface might be br-ex, so check this before looking at the hint
  while [ ${counter} -lt 12 ]; do
    # check ipv4
    # never use the interface that's specified in extra_bridge_file
    # never use br-ex1
    if [ "${extra_bridge}" != "" ]; then
      iface=$(ip route show default | grep -v "br-ex1" | grep -v "${extra_bridge}" | awk '{ if ($4 == "dev") { print $5; exit } }')
    else
      iface=$(ip route show default | grep -v "br-ex1" | awk '{ if ($4 == "dev") { print $5; exit } }')
    fi
    if [[ -n "${iface}" ]]; then
      break
    fi
    # check ipv6
    # never use the interface that's specified in extra_bridge_file
    # never use br-ex1
    if [ "${extra_bridge}" != "" ]; then
      iface=$(ip -6 route show default | grep -v "br-ex1" | grep -v "${extra_bridge}" | awk '{ if ($4 == "dev") { print $5; exit } }')
    else
      iface=$(ip -6 route show default | grep -v "br-ex1" | awk '{ if ($4 == "dev") { print $5; exit } }')
    fi
    if [[ -n "${iface}" ]]; then
      break
    fi
    counter=$((counter+1))
    sleep 5
  done

  # if the default interface does not point out of br-ex or br-ex1
  if [ "${iface}" != "br-ex" ] && [ "${iface}" != "br-ex1" ]; then
    # determine if an interface default hint exists from a previous run
    # and if the interface has a valid default route
    iface_default_hint=$(get_iface_default_hint "${iface_default_hint_file}")
    if [ "${iface_default_hint}" != "" ] &&
       [ "${iface_default_hint}" != "${iface}" ]; then
      # start wherever count left off in the previous loop
      # allow this for one more iteration than the previous loop
      while [ ${counter} -le 12 ]; do
        # check ipv4
        if [ "$(ip route show default dev "${iface_default_hint}")" != "" ]; then
          iface="${iface_default_hint}"
          break
        fi
        # check ipv6
        if [ "$(ip -6 route show default dev "${iface_default_hint}")" != "" ]; then
          iface="${iface_default_hint}"
          break
        fi
        counter=$((counter+1))
        sleep 5
      done
    fi
    # store what was determined was the (new) default interface inside
    # the default hint file for future reference
    if [ "${iface}" != "" ]; then
      write_iface_default_hint "${iface_default_hint_file}" "${iface}"
    fi
  fi
  echo "${iface}"
}

# Used to print network state
print_state() {
  echo "Current device, connection, interface and routing state:"
  nmcli -g all device | grep -v unmanaged
  nmcli -g all connection
  ip -d address show
  ip route show
  ip -6 route show
}

# Setup an exit trap to rollback on error
handle_exit() {
  e=$?
  [ $e -eq 0 ] && print_state && exit 0

  echo "ERROR: configure-ovs exited with error: $e"
  print_state

  # copy configuration to tmp
  dir=$(mktemp -d -t "configure-ovs-$(date +%Y-%m-%d-%H-%M-%S)-XXXXXXXXXX")
  update_nm_conn_conf_files br-ex phys0
  copy_nm_conn_files "$dir"
  update_nm_conn_conf_files br-ex1 phys1
  copy_nm_conn_files "$dir"
  echo "Copied OVS configuration to $dir for troubleshooting"

  # attempt to restore the previous network state
  echo "Attempting to restore previous configuration..."
  rollback_nm
  print_state

  exit $e
}
trap "handle_exit" EXIT

# Check that we are provided a valid NM connection path
if [ "$NM_CONN_SET_PATH" != "$NM_CONN_CONF_PATH" ] && [ "$NM_CONN_SET_PATH" != "$NM_CONN_RUN_PATH" ]; then
  echo "Error: Incorrect NM connection path: $NM_CONN_SET_PATH is not $NM_CONN_CONF_PATH nor $NM_CONN_RUN_PATH"
  exit 1
fi

# Clean up old config on behalf of mtu-migration
if [ ! -f /etc/cno/mtu-migration/config ]; then
  echo "Cleaning up left over mtu migration configuration"
  rm -rf /etc/cno/mtu-migration
fi

if ! rpm -qa | grep -q openvswitch; then
  echo "Warning: Openvswitch package is not installed!"
  exit 1
fi

# print initial state
print_state

if [ "$1" == "OVNKubernetes" ]; then
  # Configures NICs onto OVS bridge "br-ex"
  # Configuration is either auto-detected or provided through a config file written already in Network Manager
  # key files under /etc/NetworkManager/system-connections/
  # Managing key files is outside of the scope of this script

  # if the interface is of type vmxnet3 add multicast capability for that driver
  # REMOVEME: Once BZ:1854355 is fixed, this needs to get removed.
  function configure_driver_options {
    intf=$1
    if [ ! -f "/sys/class/net/${intf}/device/uevent" ]; then
      echo "Device file doesn't exist, skipping setting multicast mode"
    else
      driver=$(cat "/sys/class/net/${intf}/device/uevent" | grep DRIVER | awk -F "=" '{print $2}')
      echo "Driver name is" $driver
      if [ "$driver" = "vmxnet3" ]; then
        ifconfig "$intf" allmulti
      fi
    fi
  }

  ovnk_config_dir='/etc/ovnk'
  ovnk_var_dir='/var/lib/ovnk'
  extra_bridge_file="${ovnk_config_dir}/extra_bridge"
  iface_default_hint_file="${ovnk_var_dir}/iface_default_hint"
  ip_hint_file="/run/nodeip-configuration/primary-ip"

  # make sure to create ovnk_config_dir if it does not exist, yet
  mkdir -p "${ovnk_config_dir}"
  # make sure to create ovnk_var_dir if it does not exist, yet
  mkdir -p "${ovnk_var_dir}"

  # For upgrade scenarios, make sure that we stabilize what we already configured
  # before. If we do not have a valid interface hint, find the physical interface
  # that's attached to ovs-if-phys0.
  # If we find such an interface, write it to the hint file.
  iface_default_hint=$(get_iface_default_hint "${iface_default_hint_file}")
  if [ "${iface_default_hint}" == "" ]; then
    current_interface=$(get_bridge_physical_interface ovs-if-phys0)
    if [ "${current_interface}" != "" ]; then
      write_iface_default_hint "${iface_default_hint_file}" "${current_interface}"
    fi
  fi

  # delete iface_default_hint_file if it has the same content as extra_bridge_file
  # in that case, we must also force a reconfiguration of our network interfaces
  # to make sure that we reconcile this conflict
  if [ -f "${iface_default_hint_file}" ] &&
     [ -f "${extra_bridge_file}" ] &&
     [ "$(cat "${iface_default_hint_file}")" == "$(cat "${extra_bridge_file}")" ]; then
    echo "${iface_default_hint_file} and ${extra_bridge_file} share the same content"
    echo "Deleting file ${iface_default_hint_file} to choose a different interface"
    rm -f "${iface_default_hint_file}"
    rm -f /run/configure-ovs-boot-done
  fi

  # on every boot we rollback and generate the configuration again, to take
  # in any changes that have possibly been applied in the standard
  # configuration sources
  if [ ! -f /run/configure-ovs-boot-done ]; then
    echo "Running on boot, restoring previous configuration before proceeding..."
    rollback_nm
    print_state
  fi
  touch /run/configure-ovs-boot-done

  iface=$(get_nodeip_interface "${iface_default_hint_file}" "${extra_bridge_file}" "${ip_hint_file}")

  if [ "$iface" != "br-ex" ]; then
    # Default gateway is not br-ex.
    # Some deployments use a temporary solution where br-ex is moved out from the default gateway interface
    # and bound to a different nic (https://github.com/trozet/openshift-ovn-migration).
    # This is now supported through an extra bridge if requested. If that is the case, we rollback.
    # We also rollback if it looks like we need to configure things, just in case there are any leftovers
    # from previous attempts.
    if [ -f "$extra_bridge_file" ] || [ -z "$(nmcli connection show --active br-ex 2> /dev/null)" ]; then
      echo "Bridge br-ex is not active, restoring previous configuration before proceeding..."
      rollback_nm
      print_state
    fi
  fi

  convert_to_bridge "$iface" "br-ex" "phys0" "${BRIDGE_METRIC}"

  # Check if we need to configure the second bridge
  if [ -f "$extra_bridge_file" ] && (! nmcli connection show br-ex1 &> /dev/null || ! nmcli connection show ovs-if-phys1 &> /dev/null); then
    interface=$(head -n 1 $extra_bridge_file)
    convert_to_bridge "$interface" "br-ex1" "phys1" "${BRIDGE1_METRIC}"
  fi

  # Check if we need to remove the second bridge
  if [ ! -f "$extra_bridge_file" ] && (nmcli connection show br-ex1 &> /dev/null || nmcli connection show ovs-if-phys1 &> /dev/null); then
    remove_ovn_bridges br-ex1 phys1
  fi

  # Remove bridges created by openshift-sdn
  ovs-vsctl --timeout=30 --if-exists del-br br0

  # Make sure everything is activated. Do it in a specific order:
  # - activate br-ex first, due to autoconnect-slaves this will also
  #   activate ovs-port-br-ex, ovs-port-phys0 and ovs-if-phys0. It is
  #   important that ovs-if-phys0 activates with br-ex to avoid the
  #   ovs-if-phys0 profile being overridden with a profile generated from
  #   kargs. The activation of ovs-if-phys0, if a bond, might cause the
  #   slaves to re-activate, but it should be with our profiles since they
  #   have higher priority
  # - make sure that ovs-if-phys0 and its slaves, if any, are activated.
  # - finally activate ovs-if-br-ex which holds the IP configuration.
  connections=(br-ex ovs-if-phys0)
  if [ -f "$extra_bridge_file" ]; then
    connections+=(br-ex1 ovs-if-phys1)
  fi
  while IFS= read -r connection; do
    if [[ $connection == *"$MANAGED_NM_CONN_SUFFIX" ]]; then
      connections+=("$connection")
    fi
  done < <(nmcli -g NAME c)
  connections+=(ovs-if-br-ex)
  if [ -f "$extra_bridge_file" ]; then
    connections+=(ovs-if-br-ex1)
  fi
  activate_nm_connections "${connections[@]}"
  try_to_bind_ipv6_address
  set_nm_conn_files
elif [ "$1" == "OpenShiftSDN" ]; then
  # Revert changes made by /usr/local/bin/configure-ovs.sh during SDN migration.
  rollback_nm
  
  # Remove bridges created by ovn-kubernetes
  ovs-vsctl --timeout=30 --if-exists del-br br-int -- --if-exists del-br br-local
fi
