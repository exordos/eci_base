# vmagent scrape configuration.
#
# Scrapes the local node_exporter instance and forwards all collected
# metrics to the VictoriaMetrics endpoint at
# victoria-storage.local.genesis-core.tech (configured in the systemd unit).
#
# The instance label is set to the node hostname (rendered from
# __HOSTNAME__ placeholder by the systemd ExecStartPre) so that metrics
# from different nodes are distinguishable in VictoriaMetrics instead of
# all appearing as 127.0.0.1:9100.

scrape_configs:
  - job_name: "node_exporter"
    scrape_interval: 15s
    static_configs:
      - targets: ["127.0.0.1:9100"]
        labels:
          instance: "__HOSTNAME__"
