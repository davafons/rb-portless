# frozen_string_literal: true

require_relative "../test_helper"
require "json"

# Mirror of packages/portless/src/compose.test.ts

module ComposeMirror
  OPTS = {
    hostnames_for: ->(name) { [ "#{name}.localhost" ] },
    url_for: ->(hostname) { "https://#{hostname}" },
    vite_allowed_hosts: ".localhost"
  }.freeze

  def plan(services, name = "shop") = Portless::Compose.plan_compose({ "name" => name, "services" => services }, **OPTS)
  def hostnames(plan) = plan.routes.map { |r| r.hostnames[0] }

  def row(service, state, publishers, project = "shop")
    JSON.generate({ "Project" => project, "Service" => service, "State" => state, "Publishers" => publishers })
  end
end

describe "splitComposeArgs" do
  it "separates global flags, subcommand, and rest" do
    _(Portless::Compose.split_compose_args([ "-f", "a.yml", "--profile", "dev", "up", "-d", "web" ]).to_h).must_equal(
      globals: [ "-f", "a.yml", "--profile", "dev" ],
      subcommand: "up",
      rest: [ "-d", "web" ],
      docker_args: [ "-f", "a.yml", "--profile", "dev", "up", "-d", "web" ]
    )
  end

  it "handles --flag=value and boolean globals" do
    _(Portless::Compose.split_compose_args([ "--file=a.yml", "--dry-run", "down" ]).to_h).must_equal(
      globals: [ "--file=a.yml", "--dry-run" ],
      subcommand: "down",
      rest: [],
      docker_args: [ "--file=a.yml", "--dry-run", "down" ]
    )
  end

  it "keeps attached shorthand values together" do
    _(Portless::Compose.split_compose_args([ "-fcompose.yml", "-p=demo", "--profile", "dev", "up" ]).to_h).must_equal(
      globals: [ "-fcompose.yml", "-p=demo", "--profile", "dev" ],
      subcommand: "up",
      rest: [],
      docker_args: [ "-fcompose.yml", "-p=demo", "--profile", "dev", "up" ]
    )
  end

  it "ends the wrapper's globals at -- and keeps it from docker" do
    _(Portless::Compose.split_compose_args([ "-f", "a.yml", "--", "up", "-d" ]).to_h).must_equal(
      globals: [ "-f", "a.yml" ],
      subcommand: "up",
      rest: [ "-d" ],
      docker_args: [ "-f", "a.yml", "up", "-d" ]
    )
    _(Portless::Compose.split_compose_args([ "--" ]).to_h).must_equal(
      globals: [],
      subcommand: nil,
      rest: [],
      docker_args: []
    )
  end

  it "keeps a -- that belongs to the subcommand" do
    _(Portless::Compose.split_compose_args([ "up", "--", "--build" ]).to_h).must_equal(
      globals: [],
      subcommand: "up",
      rest: [ "--", "--build" ],
      docker_args: [ "up", "--", "--build" ]
    )
  end
end

describe "buildUpArgs" do
  let(:base) { { rest: [ "-d" ], project: "shop", model_path: "/state/shop.json", cwd: "/app" } }

  it "runs the model with the project, keeping other globals" do
    _(Portless::Compose.build_up_args(**base, globals: [ "-p", "x", "--profile", "dev" ])).must_equal [
      "-p",
      "shop",
      "--project-directory",
      "/app",
      "-f",
      "/state/shop.json",
      "--profile",
      "dev",
      "up",
      "-d"
    ]
  end

  it "keeps the project directory compose would use, so .env still applies" do
    dir = lambda do |globals|
      args = Portless::Compose.build_up_args(**base, globals: globals)
      args[args.index("--project-directory") + 1]
    end
    _(dir.call([])).must_equal "/app"
    _(dir.call([ "-f", "infra/compose.yml" ])).must_equal File.expand_path("infra", "/app")
    _(dir.call([ "-finfra/compose.yml" ])).must_equal File.expand_path("infra", "/app")
    _(dir.call([ "-f=infra/compose.yml" ])).must_equal File.expand_path("infra", "/app")
    _(dir.call([ "--file=infra/compose.yml", "--project-directory", "/other" ])).must_equal "/other"
    _(dir.call([ "--workdir", "/work" ])).must_equal "/work"
    _(dir.call([ "--workdir=/work", "--project-directory", "/other" ])).must_equal "/other"
  end

  it "strips attached file, project, and directory flags" do
    _(
      Portless::Compose.build_up_args(
        **base,
        globals: [
          "-fcompose.yml",
          "-p=demo",
          "--project-directory=/other",
          "--workdir=/old",
          "--profile",
          "dev"
        ]
      )
    ).must_equal [
      "-p",
      "shop",
      "--project-directory",
      "/other",
      "-f",
      "/state/shop.json",
      "--profile",
      "dev",
      "up",
      "-d"
    ]
  end

  it "strips an attached stdin file and keeps cwd" do
    _(Portless::Compose.build_up_args(**base, globals: [ "-f-" ])).must_equal [
      "-p",
      "shop",
      "--project-directory",
      "/app",
      "-f",
      "/state/shop.json",
      "up",
      "-d"
    ]
  end

  it "takes the project directory from COMPOSE_FILE when no -f is given" do
    args = Portless::Compose.build_up_args(
      **base,
      globals: [],
      compose_file_env: "infra/compose.yml|infra/override.yml",
      path_separator: "|"
    )
    _(args[args.index("--project-directory") + 1]).must_equal File.expand_path("infra", "/app")
  end
end

describe "isDetachedUp" do
  it "detects detached and wait modes" do
    _(Portless::Compose.detached_up?([ "-d" ])).must_equal true
    _(Portless::Compose.detached_up?([ "--detach", "web" ])).must_equal true
    _(Portless::Compose.detached_up?([ "--wait" ])).must_equal true
    _(Portless::Compose.detached_up?([ "--build" ])).must_equal false
  end
end

describe "planCompose" do
  include ComposeMirror

  it "moves published HTTP ports to ephemeral loopback ports" do
    p = plan({ "web" => { "ports" => [ { "target" => 80, "published" => "8080", "protocol" => "tcp" } ] } })
    _(p.routes.map(&:to_h)).must_equal [
      {
        service: "web",
        target: 80,
        hostnames: [ "web.shop.localhost" ],
        url: "https://web.shop.localhost"
      }
    ]
    _(p.model["services"]["web"]["ports"]).must_equal [
      { "target" => 80, "protocol" => "tcp", "host_ip" => "127.0.0.1" }
    ]
  end

  it "gives routed services the Vite allowed hosts, unless already set" do
    p = plan({
               "web" => { "ports" => [ { "target" => 5173, "published" => "5173" } ] },
               "api" => { "ports" => [ { "target" => 80, "published" => "80" } ], "environment" => { "X" => "1" } },
               "pinned" => {
                 "ports" => [ { "target" => 81, "published" => "81" } ],
                 "environment" => { "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => "mine" }
               },
               "worker" => { "image" => "worker" }
             })
    env = ->(s) { p.model["services"][s]["environment"] }
    _(env.call("web")).must_equal({ "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => ".localhost" })
    _(env.call("api")).must_equal({ "X" => "1", "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => ".localhost" })
    _(env.call("pinned")).must_equal({ "__VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS" => "mine" })
    _(p.model["services"]["worker"]).must_equal({ "image" => "worker" })
  end

  it "keeps database ports, UDP ports, and host networking" do
    p = plan({
               "db" => { "ports" => [ { "target" => 5432, "published" => "5432", "protocol" => "tcp" } ] },
               "dns" => { "ports" => [ { "target" => 53, "published" => "53", "protocol" => "udp" } ] },
               "host" => { "network_mode" => "host", "ports" => [ { "target" => 3000, "published" => "3000" } ] }
             })
    _(p.routes).must_equal []
    _(p.kept.map(&:service)).must_equal [ "db", "dns", "host" ]
    _(p.model["services"]["db"]["ports"][0]["published"]).must_equal "5432"
  end

  it "keeps one loopback binding per routed port and reports the dropped ones" do
    p = plan({
               "dual" => {
                 "ports" => [
                   { "target" => 80, "published" => "8090", "host_ip" => "0.0.0.0", "protocol" => "tcp" },
                   { "target" => 80, "published" => "8090", "host_ip" => "::", "protocol" => "tcp" },
                   { "target" => 80, "published" => "9090", "protocol" => "tcp" }
                 ]
               }
             })
    _(p.model["services"]["dual"]["ports"]).must_equal [
      { "target" => 80, "protocol" => "tcp", "host_ip" => "127.0.0.1" }
    ]
    _(p.kept.map(&:published)).must_equal [ "8090", "9090" ]
    _(hostnames(p)).must_equal [ "dual.shop.localhost" ]
  end

  it "names every port when a service has several" do
    p = plan({
               "app" => {
                 "ports" => [
                   { "target" => 3000, "published" => "3000" },
                   { "target" => 9229, "published" => "9229" }
                 ]
               }
             })
    _(hostnames(p)).must_equal [
      "app.shop.localhost",
      "3000.app.shop.localhost",
      "9229.app.shop.localhost"
    ]
  end

  it "normalizes names and keeps the compose project name" do
    p = plan({ "my_api" => { "ports" => [ { "target" => 8000, "published" => "8000" } ] } }, "my_shop")
    _(hostnames(p)).must_equal [ "my-api.my-shop.localhost" ]
    _(p.project).must_equal "my_shop"
  end

  it "rejects two services that map to the same hostname" do
    err = _ do
      plan({
             "my_api" => { "ports" => [ { "target" => 80, "published" => "80" } ] },
             "my-api" => { "ports" => [ { "target" => 80, "published" => "81" } ] }
           })
    end.must_raise Portless::Error
    _(err.message).must_match(/both map to my-api.shop/)
  end

  it "does not mutate the input model" do
    services = { "web" => { "ports" => [ { "target" => 80, "published" => "8080" } ] } }
    plan(services)
    _(services["web"]["ports"][0]["published"]).must_equal "8080"
  end
end

describe "service labels" do
  include ComposeMirror

  it "skips a service with portless.enable=false" do
    p = plan({
               "web" => { "labels" => { "portless.enable" => "false" },
                          "ports" => [ { "target" => 80, "published" => "8080" } ] }
             })
    _(p.routes).must_equal []
    _(p.model["services"]["web"]["ports"][0]["published"]).must_equal "8080"
  end

  it "renames the hostname with portless.name" do
    p = plan({
               "frontend_app" => {
                 "labels" => { "portless.name" => "Site" },
                 "ports" => [ { "target" => 3000, "published" => "3000" } ]
               }
             })
    _(hostnames(p)).must_equal [ "site.shop.localhost" ]
  end

  it "routes only the ports in portless.ports, including database ports" do
    p = plan({
               "app" => {
                 "labels" => { "portless.ports" => "5432" },
                 "ports" => [
                   { "target" => 5432, "published" => "5432" },
                   { "target" => 3000, "published" => "3000" }
                 ]
               }
             })
    _(p.routes.map(&:target)).must_equal [ 5432 ]
    _(p.kept.map(&:target)).must_equal [ 3000 ]
  end

  it "rejects invalid or unpublished ports in portless.ports" do
    svc = lambda do |ports|
      { "app" => { "labels" => { "portless.ports" => ports }, "ports" => [ { "target" => 3000, "published" => "3000" } ] } }
    end
    _(_ { plan(svc.call("abc")) }.must_raise(Portless::Error).message).must_match(/invalid port "abc"/)
    _(_ { plan(svc.call("3001")) }.must_raise(Portless::Error).message).must_match(/lists 3001/)
  end
end

describe "parseContainers" do
  include ComposeMirror

  it "parses one JSON object per line" do
    out = [
      row("web", "running", [ { TargetPort: 80, PublishedPort: 32_768, Protocol: "tcp" } ]),
      row("api", "running", [ { TargetPort: 80, PublishedPort: 32_769, Protocol: "tcp" } ])
    ].join("\n")
    c = Portless::Compose.parse_containers(out)
    _(c.projects).must_equal [ "shop" ]
    _(c.ports.to_a).must_equal [
      [ "web:80", 32_768 ],
      [ "api:80", 32_769 ]
    ]
  end

  it "parses the older array format" do
    c = Portless::Compose.parse_containers(
      "[#{row('web', 'running', [ { TargetPort: 80, PublishedPort: 1, Protocol: 'tcp' } ])}]"
    )
    _(c.ports["web:80"]).must_equal 1
  end

  it "lists stopped containers' projects but not their ports" do
    c = Portless::Compose.parse_containers(
      row("old", "exited", [ { TargetPort: 80, PublishedPort: 1, Protocol: "tcp" } ])
    )
    _(c.projects).must_equal [ "shop" ]
    _(c.ports.size).must_equal 0
  end

  it "returns nothing for empty output" do
    _(Portless::Compose.parse_containers("\n").to_h).must_equal({ projects: [], ports: {} })
  end
end

describe "routePort" do
  include ComposeMirror

  it "finds the host port of a planned route" do
    p = plan({ "web" => { "ports" => [ { "target" => 80, "published" => "8080" } ] } })
    c = Portless::Compose.parse_containers(
      row("web", "running", [ { TargetPort: 80, PublishedPort: 32_768, Protocol: "tcp" } ])
    )
    _(Portless::Compose.route_port(p.routes[0], c)).must_equal 32_768
    _(Portless::Compose.route_port(p.routes[0], Portless::Compose.parse_containers(""))).must_be_nil
  end
end

describe "staleAliases" do
  include ComposeMirror

  alias_row = Struct.new(:hostname, :port)
  let(:aliases) do
    [
      alias_row.new("web.shop.localhost", 32_768),
      alias_row.new("debug.shop.localhost", 32_770),
      alias_row.new("renamed.shop.localhost", 32_771),
      alias_row.new("web.myshop.localhost", 40_000),
      alias_row.new("manual.localhost", 5432)
    ]
  end

  it "removes the project's aliases whose container is gone" do
    still_running = Portless::Compose.parse_containers(
      row("debug", "running", [ { TargetPort: 80, PublishedPort: 32_770, Protocol: "tcp" } ])
    )
    _(Portless::Compose.stale_aliases(aliases, "shop", [ "localhost" ], still_running)).must_equal [
      "web.shop.localhost",
      "renamed.shop.localhost"
    ]
  end

  it "matches the project's DNS label and every TLD" do
    list = [
      alias_row.new("api.my-shop.localhost", 1),
      alias_row.new("api.my-shop.test", 1)
    ]
    _(Portless::Compose.stale_aliases(list, "my_shop", [ "localhost", "test" ],
                                      Portless::Compose.parse_containers(""))).must_equal [
                                        "api.my-shop.localhost",
                                        "api.my-shop.test"
                                      ]
  end
end

describe "readsComposeFromStdin and explicitProject" do
  it "detects -f - in any form" do
    _(Portless::Compose.reads_compose_from_stdin?([ "-f", "-" ])).must_equal true
    _(Portless::Compose.reads_compose_from_stdin?([ "-f-" ])).must_equal true
    _(Portless::Compose.reads_compose_from_stdin?([ "-f=-" ])).must_equal true
    _(Portless::Compose.reads_compose_from_stdin?([ "--file=-" ])).must_equal true
    _(Portless::Compose.reads_compose_from_stdin?([ "-f", "compose.yml" ])).must_equal false
  end

  it "reads the last -p in any form" do
    _(Portless::Compose.explicit_project([ "-p", "a", "--project-name=b" ])).must_equal "b"
    _(Portless::Compose.explicit_project([ "-pdemo" ])).must_equal "demo"
    _(Portless::Compose.explicit_project([ "-p=demo" ])).must_equal "demo"
    _(Portless::Compose.explicit_project([ "-f", "x.yml" ])).must_be_nil
  end
end

describe "fixed ports" do
  include ComposeMirror

  it "publishes the fixed host port on loopback" do
    p = Portless::Compose.plan_compose(
      { "name" => "shop", "services" => { "web" => { "ports" => [ { "target" => 80, "published" => "8080" } ] } } },
      **ComposeMirror::OPTS,
      port_for: ->(service, target) { service == "web" && target == 80 ? 14_001 : nil }
    )
    _(p.model["services"]["web"]["ports"]).must_equal [
      { "target" => 80, "host_ip" => "127.0.0.1", "published" => "14001" }
    ]
  end

  it "marks dropped duplicate bindings" do
    p = plan({
               "ext" => {
                 "ports" => [
                   { "target" => 80, "published" => "8101", "host_ip" => "0.0.0.0" },
                   { "target" => 80, "published" => "8102", "host_ip" => "::1" }
                 ]
               }
             })
    _(p.kept.length).must_equal 1
    _(p.kept[0].published).must_equal "8102"
    _(p.kept[0].dropped).must_equal true
  end
end

describe "allocatePorts" do
  let(:base) do
    {
      min: 14_000,
      max: 14_003,
      ours: Set.new,
      reserved: Set.new,
      free: ->(_port) { true },
      random: -> { 0 }
    }
  end

  it "reuses a stored port while it is free" do
    ports = Portless::Compose.allocate_ports([ "web:80" ], { "web:80" => 14_002 }, **base)
    _(ports["web:80"]).must_equal 14_002
  end

  it "reuses a stored port held by the project's own containers" do
    ports = Portless::Compose.allocate_ports(
      [ "web:80" ],
      { "web:80" => 14_002 },
      **base, ours: Set[14_002], free: ->(_port) { false }
    )
    _(ports["web:80"]).must_equal 14_002
  end

  it "replaces a stored port that another process took" do
    ports = Portless::Compose.allocate_ports(
      [ "web:80" ],
      { "web:80" => 14_002 },
      **base, free: ->(port) { port != 14_002 }
    )
    _(ports["web:80"]).must_equal 14_000
  end

  it "skips ports saved by other projects" do
    ports = Portless::Compose.allocate_ports(
      [ "web:80", "api:3000" ],
      {},
      **base,
      reserved: Set[14_000, 14_001]
    )
    _(ports.values).must_equal [ 14_002, 14_003 ]
  end

  it "gives each key its own port" do
    ports = Portless::Compose.allocate_ports([ "a:1", "b:1" ], { "a:1" => 14_001, "b:1" => 14_001 }, **base)
    _(ports["a:1"]).must_equal 14_001
    _(ports["b:1"]).must_equal 14_000
  end

  it "fails when the range is exhausted" do
    err = _ do
      Portless::Compose.allocate_ports([ "web:80" ], {}, **base, reserved: Set[14_000, 14_001, 14_002, 14_003])
    end.must_raise Portless::Error
    _(err.message).must_match(/No free port/)
  end
end

describe "composeGlobalError" do
  it "accepts %j" do
    [
      [ [ "-f", "compose.yml", "--profile", "dev", "--ansi=never", "--dry-run" ] ],
      [ [ "-fcompose.yml", "-f=compose.yml", "-pdemo", "-p=demo", "-f-", "-f=-" ] ],
      [ [ "--workdir", "/app", "--workdir=/app" ] ],
      [ [ "--dry-run=true", "--dry-run=false", "--dry-run=1", "-h", "-h=false" ] ]
    ].each do |(globals)|
      _(Portless::Compose.compose_global_error(globals)).must_be_nil
    end
  end

  it "rejects %j" do
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
    ].each do |globals, message|
      _(Portless::Compose.compose_global_error(globals)).must_equal message
    end
  end
end
