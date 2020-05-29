# frozen_string_literal: true
module StimulusReflex::ComponentRenderer
  def html
    # Temporary method of rendering a component
    # probably don't need to build a controller, request etc
    controller = request.controller_class.new
    controller.instance_variable_set :"@stimulus_reflex", true

    instance_variables.each do |name|
      controller.instance_variable_set name, instance_variable_get(name)
    end

    controller.request = request
    controller.response = ActionDispatch::Response.new
    controller.view_context.render component
  end

  def morph selectors
    selectors.map { |s| [s, html] }
  end
end
