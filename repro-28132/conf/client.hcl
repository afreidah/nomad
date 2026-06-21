data_dir  = "/data"
bind_addr = "0.0.0.0"
log_level = "WARN"

advertise {
  http = "{{ GetInterfaceIP \"eth0\" }}"
  rpc  = "{{ GetInterfaceIP \"eth0\" }}"
  serf = "{{ GetInterfaceIP \"eth0\" }}"
}

client {
  enabled = true
  server_join { retry_join = ["server"] }
}

plugin "raw_exec" {
  config { enabled = true }
}
