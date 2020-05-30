# frozen_string_literal: true

class StimulusReflex::Channel < ActionCable::Channel::Base
  include CableReady::Broadcaster

  def stream_name
    ids = connection.identifiers.map { |identifier| send(identifier).try(:id) || send(identifier) }
    [
      params[:channel],
      ids.select(&:present?).join(";")
    ].select(&:present?).join(":")
  end

  def subscribed
    stream_from stream_name
  end

  def receive(data)
    url = data["url"].to_s
    selectors = (data["selectors"] || []).select(&:present?)
    selectors = data["selectors"] = ["body"] if selectors.blank?
    target = data["target"].to_s
    reflex_name, method_name = target.split("#")
    reflex_name = reflex_name.classify
    reflex_name = reflex_name.end_with?("Reflex") ? reflex_name : "#{reflex_name}Reflex"
    arguments = (data["args"] || []).map { |arg| object_with_indifferent_access arg }
    element = StimulusReflex::Element.new(data)
    params = data["params"] || {}

    begin
      reflex_class = reflex_name.constantize.tap { |klass| raise ArgumentError.new("#{reflex_name} is not a StimulusReflex::Reflex") unless is_reflex?(klass) }
      reflex = reflex_class.new(self, url: url, element: element, selectors: selectors, method_name: method_name, params: params)
      delegate_call_to_reflex reflex, method_name, arguments
    rescue => invoke_error
      reflex.rescue_with_handler(invoke_error)
      message = exception_message_with_backtrace(invoke_error)
      return broadcast_message subject: "error", body: "StimulusReflex::Channel Failed to invoke #{target}! #{url} #{message}", data: data
    end

    if reflex.halted?
      broadcast_message subject: "halted", data: data
    else
      begin
        render_page_and_broadcast_morph reflex, selectors, data
      rescue => render_error
        reflex.rescue_with_handler(render_error)
        message = exception_message_with_backtrace(render_error)
        broadcast_message subject: "error", body: "StimulusReflex::Channel Failed to re-render #{url} #{message}", data: data
      end
    end
  end

  private

  def object_with_indifferent_access(object)
    return object.with_indifferent_access if object.respond_to?(:with_indifferent_access)
    object.map! { |obj| object_with_indifferent_access obj } if object.is_a?(Array)
    object
  end

  def is_reflex?(reflex_class)
    reflex_class.ancestors.include? StimulusReflex::Reflex
  end

  def delegate_call_to_reflex(reflex, method_name, arguments = [])
    method = reflex.method(method_name)
    required_params = method.parameters.select { |(kind, _)| kind == :req }
    optional_params = method.parameters.select { |(kind, _)| kind == :opt }

    if arguments.size == 0 && required_params.size == 0
      reflex.process(method_name)
    elsif arguments.size >= required_params.size && arguments.size <= required_params.size + optional_params.size
      reflex.process(method_name, *arguments)
    else
      raise ArgumentError.new("wrong number of arguments (given #{arguments.inspect}, expected #{required_params.inspect}, optional #{optional_params.inspect})")
    end
  end

  def render_page_and_broadcast_morph(reflex, selectors, data = {})

    morphs = if reflex.component?
      html = render_component(reflex)
      morphs = selectors.map { |s| [s, html] }
    else
      html = render_page(reflex)
      collect_morphs selectors, html
    end

    broadcast_morphs morphs, data
  end

  def commit_session(request, response)
    store = request.session.instance_variable_get("@by")
    store.commit_session request, response
  rescue => e
    message = "Failed to commit session! #{exception_message_with_backtrace(e)}"
    logger.error "\e[31m#{message}\e[0m"
  end

  def render_page(reflex)
    controller = reflex.request.controller_class.new
    controller.instance_variable_set :"@stimulus_reflex", true
    reflex.instance_variables.each do |name|
      controller.instance_variable_set name, reflex.instance_variable_get(name)
    end

    controller.request = reflex.request
    controller.response = ActionDispatch::Response.new
    controller.process reflex.url_params[:action]
    commit_session reflex.request, controller.response
    controller.response.body
  end

  def render_component(reflex)
    controller = reflex.request.controller_class.new
    controller.instance_variable_set :"@stimulus_reflex", true
    reflex.instance_variables.each do |name|
      controller.instance_variable_set name, reflex.instance_variable_get(name)
    end

    controller.request = reflex.request
    controller.response = ActionDispatch::Response.new
    controller.view_context.render reflex.component
  end

  def collect_morphs selectors, html
    document = Nokogiri::HTML(html)
    selectors = selectors.select { |s| document.css(s).present? }
    selectors.map { |s| [s, document.css(s).inner_html] }
  end

  def broadcast_morphs(morphs, data)
    morphs.each do |selector, html|
      cable_ready[stream_name].morph(
        selector: selector,
        html: html,
        children_only: true,
        permanent_attribute_name: data["permanent_attribute_name"],
        stimulus_reflex: data.merge(last: morphs == morphs.last)
      )
    end
    cable_ready.broadcast
  end

  def broadcast_message(subject:, body: nil, data: {})
    message = {
      subject: subject,
      body: body
    }

    logger.error "\e[31m#{body}\e[0m" if subject == "error"

    cable_ready[stream_name].dispatch_event(
      name: "stimulus-reflex:server-message",
      detail: {stimulus_reflex: data.merge(server_message: message)}
    )
    cable_ready.broadcast
  end

  def exception_message_with_backtrace(exception)
    "#{exception} #{exception.backtrace.first}"
  end
end
