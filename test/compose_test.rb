# frozen_string_literal: true

require_relative "test_helper"

# Port of portless's compose.test.ts.
class ComposeTest < Minitest::Test
  C = Portless::Compose

  OPTS = {
    hostnames_for: ->(name) { [ "#{name}.localhost" ] },
    url_for: ->(hostname) { "https://#{hostname}" },
    vite_allowed_hosts: ".localhost"
  }.freeze

  def plan(services, name = "shop") = C.plan_compose({ "name" => name, "services" => services }, **OPTS)
  def hostnames(plan) = plan.routes.map { |r| r.hostnames.first }

  def split(args) = C.split_compose_args(args).to_h

  # ── split_compose_args ──
  def test_split_separates_globals_subcommand_and_rest
    assert_equal({ globals: [ "-f", "a.yml", "--profile", "dev" ], subcommand: "up", rest: [ "-d", "web" ],
                   docker_args: [ "-f", "a.yml", "--profile", "dev", "up", "-d", "web" ] },
                 split([ "-f", "a.yml", "--profile", "dev", "up", "-d", "web" ]))
  end

  def test_split_handles_flag_equals_value_and_boolean_globals
    assert_equal({ globals: [ "--file=a.yml", "--dry-run" ], subcommand: "down", rest: [],
                   docker_args: [ "--file=a.yml", "--dry-run", "down" ] },
                 split([ "--file=a.yml", "--dry-run", "down" ]))
  end

  def test_split_keeps_attached_shorthand_values_together
    args = [ "-fcompose.yml", "-p=demo", "--profile", "dev", "up" ]
    assert_equal({ globals: args[0, 4], subcommand: "up", rest: [], docker_args: args }, split(args))
  end

  def test_split_ends_wrapper_globals_at_double_dash
    assert_equal({ globals: [ "-f", "a.yml" ], subcommand: "up", rest: [ "-d" ], docker_args: [ "-f", "a.yml", "up", "-d" ] },
                 split([ "-f", "a.yml", "--", "up", "-d" ]))
    assert_equal({ globals: [], subcommand: nil, rest: [], docker_args: [] }, split([ "--" ]))
  end

  def test_split_keeps_a_double_dash_that_belongs_to_the_subcommand
    assert_equal({ globals: [], subcommand: "up", rest: [ "--", "--build" ], docker_args: [ "up", "--", "--build" ] },
                 split([ "up", "--", "--build" ]))
  end

  # ── build_up_args ──
  BASE = { rest: [ "-d" ], project: "shop", model_path: "/state/shop.json", cwd: "/app" }.freeze

  def up_dir(globals, **extra)
    args = C.build_up_args(**BASE, globals: globals, **extra)
    args[args.index("--project-directory") + 1]
  end

  def test_build_up_args_runs_the_model_keeping_other_globals
    assert_equal [ "-p", "shop", "--project-directory", "/app", "-f", "/state/shop.json", "--profile", "dev", "up", "-d" ],
                 C.build_up_args(**BASE, globals: [ "-p", "x", "--profile", "dev" ])
  end

  def test_build_up_args_keeps_the_project_directory_compose_would_use
    assert_equal "/app", up_dir([])
    assert_equal "/app/infra", up_dir([ "-f", "infra/compose.yml" ])
    assert_equal "/app/infra", up_dir([ "-finfra/compose.yml" ])
    assert_equal "/app/infra", up_dir([ "-f=infra/compose.yml" ])
    assert_equal "/other", up_dir([ "--file=infra/compose.yml", "--project-directory", "/other" ])
    assert_equal "/work", up_dir([ "--workdir", "/work" ])
    assert_equal "/other", up_dir([ "--workdir=/work", "--project-directory", "/other" ])
  end

  def test_build_up_args_strips_attached_file_project_and_directory_flags
    globals = [ "-fcompose.yml", "-p=demo", "--project-directory=/other", "--workdir=/old", "--profile", "dev" ]
    assert_equal [ "-p", "shop", "--project-directory", "/other", "-f", "/state/shop.json", "--profile", "dev", "up", "-d" ],
                 C.build_up_args(**BASE, globals: globals)
  end

  def test_build_up_args_strips_an_attached_stdin_file_and_keeps_cwd
    assert_equal [ "-p", "shop", "--project-directory", "/app", "-f", "/state/shop.json", "up", "-d" ],
                 C.build_up_args(**BASE, globals: [ "-f-" ])
  end

  def test_build_up_args_takes_the_project_directory_from_compose_file
    assert_equal "/app/infra",
                 up_dir([], compose_file_env: "infra/compose.yml|infra/override.yml", path_separator: "|")
  end

  def test_detached_up
    assert C.detached_up?([ "-d" ])
    assert C.detached_up?([ "--detach", "web" ])
    assert C.detached_up?([ "--wait" ])
    refute C.detached_up?([ "--build" ])
  end

  # ── plan_compose ──
  def test_moves_published_http_ports_to_ephemeral_loopback_ports
    p = plan({ "web" => { "ports" => [ { "target" => 80, "published" => "8080", "protocol" => "tcp" } ] } })
    assert_equal [ C::ComposeRoute.new(service: "web", target: 80, hostnames: [ "web.shop.localhost" ],
                                       url: "https://web.shop.localhost") ], p.routes
    assert_equal [ { "target" => 80, "protocol" => "tcp", "host_ip" => "127.0.0.1" } ], p.model["services"]["web"]["ports"]
  end

  def test_gives_routed_services_the_vite_allowed_hosts_unless_already_set
    p = plan({
               "web" => { "ports" => [ { "target" => 5173, "published" => "5173" } ] },
               "api" => { "ports" => [ { "target" => 80, "published" => "80" } ], "environment" => { "X" => "1" } },
               "pinned" => { "ports" => [ { "target" => 81, "published" => "81" } ],
                             "environment" => { "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => "mine" } },
               "worker" => { "image" => "worker" }
             })
    env = ->(s) { p.model["services"][s]["environment"] }
    assert_equal({ "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => ".localhost" }, env.("web"))
    assert_equal({ "X" => "1", "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => ".localhost" }, env.("api"))
    assert_equal({ "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => "mine" }, env.("pinned"))
    assert_equal({ "image" => "worker" }, p.model["services"]["worker"])
  end

  def test_keeps_database_ports_udp_ports_and_host_networking
    p = plan({
               "db" => { "ports" => [ { "target" => 5432, "published" => "5432", "protocol" => "tcp" } ] },
               "dns" => { "ports" => [ { "target" => 53, "published" => "53", "protocol" => "udp" } ] },
               "host" => { "network_mode" => "host", "ports" => [ { "target" => 3000, "published" => "3000" } ] }
             })
    assert_empty p.routes
    assert_equal %w[db dns host], p.kept.map(&:service)
    assert_equal "5432", p.model["services"]["db"]["ports"][0]["published"]
  end

  def test_keeps_one_loopback_binding_per_routed_port_and_reports_dropped_ones
    p = plan({ "dual" => { "ports" => [
               { "target" => 80, "published" => "8090", "host_ip" => "0.0.0.0", "protocol" => "tcp" },
               { "target" => 80, "published" => "8090", "host_ip" => "::", "protocol" => "tcp" },
               { "target" => 80, "published" => "9090", "protocol" => "tcp" }
             ] } })
    assert_equal [ { "target" => 80, "protocol" => "tcp", "host_ip" => "127.0.0.1" } ], p.model["services"]["dual"]["ports"]
    assert_equal %w[8090 9090], p.kept.map(&:published)
    assert_equal [ "dual.shop.localhost" ], hostnames(p)
  end

  def test_names_every_port_when_a_service_has_several
    p = plan({ "app" => { "ports" => [ { "target" => 3000, "published" => "3000" },
                                       { "target" => 9229, "published" => "9229" } ] } })
    assert_equal %w[app.shop.localhost 3000.app.shop.localhost 9229.app.shop.localhost], hostnames(p)
  end

  def test_normalizes_names_and_keeps_the_compose_project_name
    p = plan({ "my_api" => { "ports" => [ { "target" => 8000, "published" => "8000" } ] } }, "my_shop")
    assert_equal [ "my-api.my-shop.localhost" ], hostnames(p)
    assert_equal "my_shop", p.project
  end

  def test_rejects_two_services_that_map_to_the_same_hostname
    error = assert_raises(Portless::Error) do
      plan({ "my_api" => { "ports" => [ { "target" => 80, "published" => "80" } ] },
             "my-api" => { "ports" => [ { "target" => 80, "published" => "81" } ] } })
    end
    assert_match(/both map to my-api.shop/, error.message)
  end

  def test_does_not_mutate_the_input_model
    services = { "web" => { "ports" => [ { "target" => 80, "published" => "8080" } ] } }
    plan(services)
    assert_equal "8080", services["web"]["ports"][0]["published"]
    refute services["web"].key?("environment")
  end

  # ── service labels ──
  def test_skips_a_service_with_portless_enable_false
    p = plan({ "web" => { "labels" => { "portless.enable" => "false" },
                          "ports" => [ { "target" => 80, "published" => "8080" } ] } })
    assert_empty p.routes
    assert_equal "8080", p.model["services"]["web"]["ports"][0]["published"]
  end

  def test_renames_the_hostname_with_portless_name
    p = plan({ "frontend_app" => { "labels" => { "portless.name" => "Site" },
                                   "ports" => [ { "target" => 3000, "published" => "3000" } ] } })
    assert_equal [ "site.shop.localhost" ], hostnames(p)
  end

  def test_routes_only_the_ports_in_portless_ports_including_database_ports
    p = plan({ "app" => { "labels" => { "portless.ports" => "5432" },
                          "ports" => [ { "target" => 5432, "published" => "5432" },
                                       { "target" => 3000, "published" => "3000" } ] } })
    assert_equal [ 5432 ], p.routes.map(&:target)
    assert_equal [ 3000 ], p.kept.map(&:target)
  end

  def test_rejects_invalid_or_unpublished_ports_in_portless_ports
    svc = ->(ports) { { "app" => { "labels" => { "portless.ports" => ports }, "ports" => [ { "target" => 3000, "published" => "3000" } ] } } }
    assert_match(/invalid port "abc"/, assert_raises(Portless::Error) { plan(svc.("abc")) }.message)
    assert_match(/lists 3001/, assert_raises(Portless::Error) { plan(svc.("3001")) }.message)
  end

  # ── parse_containers ──
  def row(service, state, publishers, project = "shop")
    JSON.generate({ "Project" => project, "Service" => service, "State" => state, "Publishers" => publishers })
  end

  def pub(target, published) = { "TargetPort" => target, "PublishedPort" => published, "Protocol" => "tcp" }

  def test_parses_one_json_object_per_line
    c = C.parse_containers([ row("web", "running", [ pub(80, 32_768) ]), row("api", "running", [ pub(80, 32_769) ]) ].join("\n"))
    assert_equal [ "shop" ], c.projects
    assert_equal [ [ "web:80", 32_768 ], [ "api:80", 32_769 ] ], c.ports.to_a
  end

  def test_parses_the_older_array_format
    c = C.parse_containers("[#{row('web', 'running', [ pub(80, 1) ])}]")
    assert_equal 1, c.ports["web:80"]
  end

  def test_lists_stopped_containers_projects_but_not_their_ports
    c = C.parse_containers(row("old", "exited", [ pub(80, 1) ]))
    assert_equal [ "shop" ], c.projects
    assert_empty c.ports
  end

  def test_returns_nothing_for_empty_output
    c = C.parse_containers("\n")
    assert_equal [], c.projects
    assert_equal({}, c.ports)
  end

  def test_route_port_finds_the_host_port_of_a_planned_route
    p = plan({ "web" => { "ports" => [ { "target" => 80, "published" => "8080" } ] } })
    assert_equal 32_768, C.route_port(p.routes[0], C.parse_containers(row("web", "running", [ pub(80, 32_768) ])))
    assert_nil C.route_port(p.routes[0], C.parse_containers(""))
  end

  # ── stale_aliases ──
  Alias = Struct.new(:hostname, :port)

  def test_removes_the_projects_aliases_whose_container_is_gone
    aliases = [ Alias.new("web.shop.localhost", 32_768), Alias.new("debug.shop.localhost", 32_770),
                Alias.new("renamed.shop.localhost", 32_771), Alias.new("web.myshop.localhost", 40_000),
                Alias.new("manual.localhost", 5432) ]
    still_running = C.parse_containers(row("debug", "running", [ pub(80, 32_770) ]))
    assert_equal %w[web.shop.localhost renamed.shop.localhost],
                 C.stale_aliases(aliases, "shop", [ "localhost" ], still_running)
  end

  def test_stale_aliases_match_the_projects_dns_label_and_every_tld
    list = [ Alias.new("api.my-shop.localhost", 1), Alias.new("api.my-shop.test", 1) ]
    assert_equal %w[api.my-shop.localhost api.my-shop.test],
                 C.stale_aliases(list, "my_shop", %w[localhost test], C.parse_containers(""))
  end

  # ── reads_compose_from_stdin? / explicit_project ──
  def test_detects_stdin_file_in_any_form
    assert C.reads_compose_from_stdin?([ "-f", "-" ])
    assert C.reads_compose_from_stdin?([ "-f-" ])
    assert C.reads_compose_from_stdin?([ "-f=-" ])
    assert C.reads_compose_from_stdin?([ "--file=-" ])
    refute C.reads_compose_from_stdin?([ "-f", "compose.yml" ])
  end

  def test_reads_the_last_project_in_any_form
    assert_equal "b", C.explicit_project([ "-p", "a", "--project-name=b" ])
    assert_equal "demo", C.explicit_project([ "-pdemo" ])
    assert_equal "demo", C.explicit_project([ "-p=demo" ])
    assert_nil C.explicit_project([ "-f", "x.yml" ])
  end

  # ── fixed ports ──
  def test_publishes_the_fixed_host_port_on_loopback
    p = C.plan_compose({ "name" => "shop", "services" => { "web" => { "ports" => [ { "target" => 80, "published" => "8080" } ] } } },
                       **OPTS, port_for: ->(service, target) { service == "web" && target == 80 ? 14_001 : nil })
    assert_equal [ { "target" => 80, "host_ip" => "127.0.0.1", "published" => "14001" } ], p.model["services"]["web"]["ports"]
  end

  def test_marks_dropped_duplicate_bindings
    p = plan({ "ext" => { "ports" => [ { "target" => 80, "published" => "8101", "host_ip" => "0.0.0.0" },
                                       { "target" => 80, "published" => "8102", "host_ip" => "::1" } ] } })
    assert_equal 1, p.kept.length
    assert_equal "8102", p.kept[0].published
    assert p.kept[0].dropped
  end

  # ── allocate_ports ──
  ALLOC = { min: 14_000, max: 14_003, ours: [], reserved: [], free: ->(_) { true }, random: -> { 0 } }.freeze

  def alloc(keys, stored, **over) = C.allocate_ports(keys, stored, **ALLOC, **over)

  def test_reuses_a_stored_port_while_it_is_free
    assert_equal 14_002, alloc([ "web:80" ], { "web:80" => 14_002 })["web:80"]
  end

  def test_reuses_a_stored_port_held_by_the_projects_own_containers
    assert_equal 14_002, alloc([ "web:80" ], { "web:80" => 14_002 }, ours: [ 14_002 ], free: ->(_) { false })["web:80"]
  end

  def test_replaces_a_stored_port_that_another_process_took
    assert_equal 14_000, alloc([ "web:80" ], { "web:80" => 14_002 }, free: ->(port) { port != 14_002 })["web:80"]
  end

  def test_skips_ports_saved_by_other_projects
    assert_equal [ 14_002, 14_003 ], alloc([ "web:80", "api:3000" ], {}, reserved: [ 14_000, 14_001 ]).values
  end

  def test_gives_each_key_its_own_port
    ports = alloc([ "a:1", "b:1" ], { "a:1" => 14_001, "b:1" => 14_001 })
    assert_equal 14_001, ports["a:1"]
    assert_equal 14_000, ports["b:1"]
  end

  def test_fails_when_the_range_is_exhausted
    error = assert_raises(Portless::Error) { alloc([ "web:80" ], {}, reserved: [ 14_000, 14_001, 14_002, 14_003 ]) }
    assert_match(/No free port/, error.message)
  end

  # ── compose_global_error ──
  def test_accepts_valid_globals
    [
      [ "-f", "compose.yml", "--profile", "dev", "--ansi=never", "--dry-run" ],
      [ "-fcompose.yml", "-f=compose.yml", "-pdemo", "-p=demo", "-f-", "-f=-" ],
      [ "--workdir", "/app", "--workdir=/app" ],
      [ "--dry-run=true", "--dry-run=false", "--dry-run=1", "-h", "-h=false" ]
    ].each { |globals| assert_nil C.compose_global_error(globals), globals.inspect }
  end

  def test_rejects_invalid_globals
    [
      [ [ "--bad" ], 'Unknown flag "--bad" for rb-portless compose.' ],
      [ [ "-x" ], 'Unknown flag "-x" for rb-portless compose.' ],
      [ [ "-w", "/app" ], 'Unknown flag "-w" for rb-portless compose.' ],
      [ [ "-f" ], "-f requires a value." ],
      [ [ "-f=" ], "-f requires a value." ],
      [ [ "-f", "" ], "-f requires a value." ],
      [ [ "--file", "", "ps" ], "--file requires a value." ],
      [ [ "--env-file=" ], "--env-file requires a value." ],
      [ [ "--dry-run=yes" ], "--dry-run takes true or false." ],
      [ [ "-h=yes" ], "-h takes true or false." ]
    ].each { |globals, message| assert_equal message, C.compose_global_error(globals), globals.inspect }
  end
end
