# frozen_string_literal: true

require "action_view"
require "active_support/configurable"
require "view_component/collection"
require "view_component/compile_cache"
require "view_component/previewable"
require "view_component/slotable"

module ViewComponent
  class Base < ActionView::Base
    include ActiveSupport::Configurable
    include ViewComponent::Previewable

    ViewContextCalledBeforeRenderError = Class.new(StandardError)

    # For CSRF authenticity tokens in forms
    delegate :form_authenticity_token, :protect_against_forgery?, :config, to: :helpers

    class_attribute :content_areas
    self.content_areas = [] # class_attribute:default doesn't work until Rails 5.2

    # Hash of registered Slots
    class_attribute :slots
    self.slots = {}

    # Entrypoint for rendering components.
    #
    # view_context: ActionView context from calling view
    # block: optional block to be captured within the view context
    #
    # returns HTML that has been escaped by the respective template handler
    #
    # Example subclass:
    #
    # app/components/my_component.rb:
    # class MyComponent < ViewComponent::Base
    #   def initialize(title:)
    #     @title = title
    #   end
    # end
    #
    # app/components/my_component.html.erb
    # <span title="<%= @title %>">Hello, <%= content %>!</span>
    #
    # In use:
    # <%= render MyComponent.new(title: "greeting") do %>world<% end %>
    # returns:
    # <span title="greeting">Hello, world!</span>
    #
    def render_in(view_context, &block)
      self.class.compile(raise_errors: true)

      @view_context = view_context
      @lookup_context ||= view_context.lookup_context

      # required for path helpers in older Rails versions
      @view_renderer ||= view_context.view_renderer

      # For content_for
      @view_flow ||= view_context.view_flow

      # For i18n
      @virtual_path ||= virtual_path

      # For template variants (+phone, +desktop, etc.)
      @variant ||= @lookup_context.variants.first

      # For caching, such as #cache_if
      @current_template = nil unless defined?(@current_template)
      old_current_template = @current_template
      @current_template = self

      # Assign captured content passed to component as a block to @content
      @content = view_context.capture(self, &block) if block_given?

      before_render

      if render?
        render_template_for(@variant)
      else
        ""
      end
    ensure
      @current_template = old_current_template
    end

    def before_render
      before_render_check
    end

    def before_render_check
      # noop
    end

    def render?
      true
    end

    def initialize(*); end

    # If trying to render a partial or template inside a component,
    # pass the render call to the parent view_context.
    def render(options = {}, args = {}, &block)
      view_context.render(options, args, &block)
    end

    def controller
      raise ViewContextCalledBeforeRenderError, "`controller` can only be called at render time." if view_context.nil?
      @controller ||= view_context.controller
    end

    # Provides a proxy to access helper methods from the context of the current controller
    def helpers
      raise ViewContextCalledBeforeRenderError, "`helpers` can only be called at render time." if view_context.nil?
      @helpers ||= view_context
    end

    # Exposes .virutal_path as an instance method
    def virtual_path
      self.class.virtual_path
    end

    # For caching, such as #cache_if
    def view_cache_dependencies
      []
    end

    # For caching, such as #cache_if
    def format
      @variant
    end

    # Assign the provided content to the content area accessor
    def with(area, content = nil, &block)
      unless content_areas.include?(area)
        raise ArgumentError.new "Unknown content_area '#{area}' - expected one of '#{content_areas}'"
      end

      if block_given?
        content = view_context.capture(&block)
      end

      instance_variable_set("@#{area}".to_sym, content)
      nil
    end

    def with_variant(variant)
      @variant = variant

      self
    end

    private

    # Exposes the current request to the component.
    # Use sparingly as doing so introduces coupling
    # that inhibits encapsulation & reuse.
    def request
      @request ||= controller.request
    end

    attr_reader :content, :view_context

    # The controller used for testing components.
    # Defaults to ApplicationController. This should be set early
    # in the initialization process and should be set to a string.
    mattr_accessor :test_controller
    @@test_controller = "ApplicationController"

    # Configure if render monkey patches should be included or not in Rails <6.1.
    mattr_accessor :render_monkey_patch_enabled, instance_writer: false, default: true

    class << self
      attr_accessor :source_location, :virtual_path

      # Render a component collection.
      def with_collection(collection, **args)
        Collection.new(self, collection, **args)
      end

      # Provide identifier for ActionView template annotations
      def short_identifier
        @short_identifier ||= defined?(Rails.root) ? source_location.sub("#{Rails.root}/", "") : source_location
      end

      def inherited(child)
        # Compile so child will inherit compiled `call_*` template methods that
        # `compile` defines
        compile

        # If Rails application is loaded, add application url_helpers to the component context
        # we need to check this to use this gem as a dependency
        if defined?(Rails) && Rails.application
          child.include Rails.application.routes.url_helpers unless child < Rails.application.routes.url_helpers
        end

        # Derive the source location of the component Ruby file from the call stack.
        # We need to ignore `inherited` frames here as they indicate that `inherited`
        # has been re-defined by the consuming application, likely in ApplicationComponent.
        child.source_location = caller_locations(1, 10).reject { |l| l.label == "inherited" }[0].absolute_path

        # Removes the first part of the path and the extension.
        child.virtual_path = child.source_location.gsub(%r{(.*app/components)|(\.rb)}, "")

        # Clone slot configuration into child class
        # see #test_slots_pollution
        child.slots = self.slots.clone

        super
      end

      def compiled?
        template_compiler.compiled?
      end

      # Compile templates to instance methods, assuming they haven't been compiled already.
      #
      # Do as much work as possible in this step, as doing so reduces the amount
      # of work done each time a component is rendered.
      def compile(raise_errors: false)
        template_compiler.compile(raise_errors: raise_errors)
      end

      def template_compiler
        @_template_compiler ||= Compiler.new(self)
      end

      # we'll eventually want to update this to support other types
      def type
        "text/html"
      end

      def format
        :html
      end

      def identifier
        source_location
      end

      def with_content_areas(*areas)
        if areas.include?(:content)
          raise ArgumentError.new ":content is a reserved content area name. Please use another name, such as ':body'"
        end
        attr_reader(*areas)
        self.content_areas = areas
      end

      # Support overriding collection parameter name
      def with_collection_parameter(param)
        @provided_collection_parameter = param
      end

      # Ensure the component initializer accepts the
      # collection parameter. By default, we do not
      # validate that the default parameter name
      # is accepted, as support for collection
      # rendering is optional.
      def validate_collection_parameter!(validate_default: false)
        parameter = validate_default ? collection_parameter : provided_collection_parameter

        return unless parameter
        return if initialize_parameters.map(&:last).include?(parameter)

        # If Ruby cannot parse the component class, then the initalize
        # parameters will be empty and ViewComponent will not be able to render
        # the component.
        if initialize_parameters.empty?
          raise ArgumentError.new(
            "#{self} initializer is empty or invalid."
          )
        end

        raise ArgumentError.new(
          "#{self} initializer must accept " \
          "`#{parameter}` collection parameter."
        )
      end

      private

      def initialize_parameters
        instance_method(:initialize).parameters
      end

      def provided_collection_parameter
        @provided_collection_parameter ||= nil
      end

    end

    ActiveSupport.run_load_hooks(:view_component, self)
  end
end
