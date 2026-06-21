data_dir  = "/data"
bind_addr = "0.0.0.0"
log_level = "WARN"

advertise {
  http = "{{ GetInterfaceIP \"eth0\" }}"
  rpc  = "{{ GetInterfaceIP \"eth0\" }}"
  serf = "{{ GetInterfaceIP \"eth0\" }}"
}

server {
  enabled           = true
  bootstrap_expect  = 1
  heartbeat_grace   = "8s"
  min_heartbeat_ttl = "3s"
}
