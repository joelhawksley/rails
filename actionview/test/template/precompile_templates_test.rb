# frozen_string_literal: true

require "abstract_unit"

class PrecompileTemplatesTest < ActiveSupport::TestCase
  def setup
    super
    @old_precompile = ActionView::Base.precompile_templates
    ActionController::Base.view_paths.each(&:clear_cache)
  end

  def teardown
    ActionView::Base.precompile_templates = @old_precompile
    ActionController::Base.view_paths.each(&:clear_cache)
    ActionView::LookupContext::DetailsKey.clear
    super
  end

  def test_precompile_templates_compiles_strict_locals_templates
    ActionView::Base.precompile_templates = true

    # Verify that the fixture template file exists
    resolver = ActionController::Base.view_paths.paths.first
    template_path = File.join(resolver.path, "test", "precompile_strict_locals.html.erb")
    assert File.exist?(template_path), "Fixture template must exist"

    # Precompile templates
    ActionView::Template.precompile!

    # Look up the template through the resolver with a cache key — since
    # precompile! populated @unbound_templates, we get the same Template object.
    details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
    key = ActionView::LookupContext::DetailsKey.details_cache_key(details)
    templates = resolver.find_all("precompile_strict_locals", "test", false, details, key, [])
    assert_not_empty templates, "Expected to find the strict locals template"

    template = templates.first
    assert template.strict_locals?, "Expected template to use strict locals"
    assert template.instance_variable_get(:@compiled),
      "Expected strict locals template to be compiled after precompile!"
  end

  def test_precompile_skipped_when_disabled
    ActionView::Base.precompile_templates = false

    ActionView::Template.precompile!

    resolver = ActionController::Base.view_paths.paths.first
    details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
    key = ActionView::LookupContext::DetailsKey.details_cache_key(details)
    templates = resolver.find_all("precompile_strict_locals", "test", false, details, key, [])
    assert_not_empty templates

    template = templates.first
    assert_not template.instance_variable_get(:@compiled),
      "Expected strict locals template NOT to be compiled when precompile_templates is false"
  end

  def test_precompile_only_compiles_strict_locals_templates
    ActionView::Base.precompile_templates = true

    ActionView::Template.precompile!

    # A template without strict locals should not be compiled (module_eval)
    resolver = ActionController::Base.view_paths.paths.first
    details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
    key = ActionView::LookupContext::DetailsKey.details_cache_key(details)
    templates = resolver.find_all("hello_world", "test", false, details, key, [])
    assert_not_empty templates, "Non-strict-locals fixture must exist"

    template = templates.first
    assert_not template.instance_variable_get(:@compiled),
      "Expected non-strict-locals template NOT to be compiled by precompile!"
  end

  def test_precompile_caches_handler_output_for_all_templates
    ActionView::Base.precompile_templates = true

    ActionView::Template.precompile!

    resolver = ActionController::Base.view_paths.paths.first

    # Non-strict-locals template should have handler output cached
    details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
    key = ActionView::LookupContext::DetailsKey.details_cache_key(details)
    templates = resolver.find_all("hello_world", "test", false, details, key, [])
    assert_not_empty templates

    template = templates.first
    handler_code = template.instance_variable_get(:@handler_compiled_code)
    assert_not_nil handler_code,
      "Expected handler output to be cached for non-strict-locals template"
    assert_includes handler_code, "Hello world!",
      "Expected cached handler output to contain template content"
  end

  def test_precompile_caches_handler_output_for_strict_locals_templates
    ActionView::Base.precompile_templates = true

    ActionView::Template.precompile!

    resolver = ActionController::Base.view_paths.paths.first
    details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
    key = ActionView::LookupContext::DetailsKey.details_cache_key(details)
    templates = resolver.find_all("precompile_strict_locals", "test", false, details, key, [])
    assert_not_empty templates

    template = templates.first
    handler_code = template.instance_variable_get(:@handler_compiled_code)
    assert_not_nil handler_code,
      "Expected handler output to be cached for strict-locals template"
  end

  def test_cached_handler_output_is_used_for_new_locals_variants
    ActionView::Base.precompile_templates = true

    ActionView::Template.precompile!

    resolver = ActionController::Base.view_paths.paths.first
    details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
    key = ActionView::LookupContext::DetailsKey.details_cache_key(details)

    # First lookup with empty locals (created during precompile!)
    templates_empty = resolver.find_all("hello_world", "test", false, details, key, [])
    cached_code = templates_empty.first.instance_variable_get(:@handler_compiled_code)

    # Clear the resolver cache and re-populate to get new Template instances
    resolver.clear_cache
    ActionView::Template.precompile!

    # New lookup with different locals — should still have cached handler code
    templates_with_locals = resolver.find_all("hello_world", "test", false, details, key, [:foo])
    new_template = templates_with_locals.first
    assert_equal cached_code, new_template.instance_variable_get(:@handler_compiled_code),
      "Expected new template with different locals to receive cached handler code"
  end

  def test_handler_output_not_cached_when_precompile_disabled
    ActionView::Base.precompile_templates = false

    ActionView::Template.precompile!

    resolver = ActionController::Base.view_paths.paths.first
    details = { locale: [:en], formats: [:html], variants: [], handlers: [:erb] }
    key = ActionView::LookupContext::DetailsKey.details_cache_key(details)
    templates = resolver.find_all("hello_world", "test", false, details, key, [])
    assert_not_empty templates

    template = templates.first
    assert_nil template.instance_variable_get(:@handler_compiled_code),
      "Expected handler output NOT to be cached when precompile_templates is false"
  end
end
