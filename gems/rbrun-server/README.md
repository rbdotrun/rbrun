# rbrun-server

Server providers for rbrun behind one provision/deploy contract (`Rbrun::Server::Base`). `kamal_hetzner`
today: provision on Hetzner Cloud (HTTP API over Faraday/async-http), deploy via Kamal's local builder.
Pure gem — depends on no other rbrun gem. The engine owns config; the adapter validates its own and fails
fast.
