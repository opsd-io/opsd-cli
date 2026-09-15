# frozen_string_literal: true

module OPSd
  module WizardCatalog
    FIELDS = {
      "project_name" => {
        label: "Project name",
        description: "Human-readable name for the environment and generated project.",
        type: :string,
        required: true,
        targets: [%w[metadata name], %w[spec defaults project]],
        placeholder_values: []
      },
      "region" => {
        label: "Region",
        description: "DigitalOcean region slug where resources will be created.",
        type: :enum,
        required: true,
        default: "fra1",
        choices: %w[fra1 ams3 nyc1 sfo3],
        targets: [%w[metadata region]]
      },
      "source_mode" => {
        label: "Source provider",
        description: "Select where the application source lives.",
        type: :enum,
        required: true,
        choices: %w[image github gitlab],
        targets: [%w[spec compute_groups 0 delivery mode], %w[spec compute_groups 0 delivery source mode]]
      },
      "image_repository" => {
        label: "Image repository",
        description: "Container image repository, for example nginx or org/image.",
        type: :string,
        required: true,
        targets: [%w[spec compute_groups 0 delivery source image repository]],
        when: { "source_mode" => "image" },
        placeholder_values: ["replace-with-your-image-repository"]
      },
      "image_tag" => {
        label: "Image tag",
        description: "Container image tag or version.",
        type: :string,
        required: true,
        default: "latest",
        targets: [%w[spec compute_groups 0 delivery source image tag]],
        when: { "source_mode" => "image" }
      },
      "github_repo" => {
        label: "GitHub repository",
        description: "Repository in owner/repo format.",
        type: :string,
        required: true,
        targets: [%w[spec compute_groups 0 delivery source github repository]],
        when: { "source_mode" => "github" },
        placeholder_values: ["replace-with-your-github-repository"]
      },
      "github_branch" => {
        label: "GitHub branch",
        description: "Branch used for deployment.",
        type: :string,
        required: true,
        default: "main",
        targets: [%w[spec compute_groups 0 delivery source github branch]],
        when: { "source_mode" => "github" }
      },
      "gitlab_repo" => {
        label: "GitLab repository",
        description: "Repository in owner/repo or owner/group/repo format.",
        type: :string,
        required: true,
        targets: [%w[spec compute_groups 0 delivery source gitlab repository]],
        when: { "source_mode" => "gitlab" },
        placeholder_values: ["replace-with-your-gitlab-repository"]
      },
      "gitlab_branch" => {
        label: "GitLab branch",
        description: "Branch used for deployment.",
        type: :string,
        required: true,
        default: "main",
        targets: [%w[spec compute_groups 0 delivery source gitlab branch]],
        when: { "source_mode" => "gitlab" }
      },
      "replicas" => {
        label: "Instance count",
        description: "How many workload instances should run.",
        type: :integer,
        required: true,
        default: 1,
        min: 1,
        step: 1,
        targets: [%w[spec compute_groups 0 replicas]]
      },
      "dns_enabled" => {
        label: "Enable DNS",
        description: "Whether this workload should emit DNS records.",
        type: :boolean,
        required: true,
        default: false,
        targets: [%w[spec compute_groups 0 exposure dns enabled]]
      },
      "dns_manage_zone" => {
        label: "Manage DNS zone in DigitalOcean",
        description: "Create the DNS zone in DigitalOcean instead of using an existing one.",
        type: :boolean,
        required: true,
        default: true,
        targets: [%w[spec compute_groups 0 exposure dns manage_zone]],
        when: { "dns_enabled" => true }
      },
      "dns_domain" => {
        label: "Primary domain",
        description: "Apex domain used for the workload.",
        type: :string,
        required: true,
        targets: [%w[spec defaults dns_zone], %w[spec compute_groups 0 exposure dns domain]],
        when: { "dns_enabled" => true }
      },
      "dns_record" => {
        label: "DNS record",
        description: "Record name used for the public endpoint.",
        type: :string,
        required: true,
        default: "app",
        targets: [%w[spec compute_groups 0 exposure dns record]],
        when: { "dns_enabled" => true }
      },
      "dns_target_ref" => {
        label: "DNS target",
        description: "Optional node id for an A record that should resolve to a managed node.",
        type: :string,
        required: false,
        targets: [%w[spec compute_groups 0 exposure dns target_ref]],
        when: { "dns_enabled" => true }
      },
      "dns_www_domain" => {
        label: "WWW domain",
        description: "Optional explicit www domain when the DNS zone is managed externally.",
        type: :string,
        required: false,
        targets: [%w[spec compute_groups 0 exposure dns www_domain]],
        when: { "dns_enabled" => true }
      },
      "database_engine" => {
        label: "Database engine",
        description: "Managed database engine used by the workload.",
        type: :enum,
        required: true,
        choices: %w[postgres mysql],
        targets: [%w[spec databases 0 engine]]
      },
      "database_profile" => {
        label: "Database size",
        description: "Managed database profile slug.",
        type: :enum,
        required: true,
        choices: %w[db-s-1vcpu-1gb db-s-2vcpu-4gb],
        targets: [%w[spec databases 0 profile]]
      }
    }.freeze

    def self.field(field_id)
      FIELDS.fetch(field_id)
    end
  end
end
