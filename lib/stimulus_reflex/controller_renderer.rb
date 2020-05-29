# frozen_string_literal: true
module StimulusReflex::ControllerRenderer
  def html
    # Moved from Channel#render_page
    controller = request.controller_class.new
    controller.instance_variable_set :"@stimulus_reflex", true
    instance_variables.each do |name|
      controller.instance_variable_set name, instance_variable_get(name)
    end

    controller.request = request
    controller.response = ActionDispatch::Response.new
    controller.process url_params[:action]
    commit_session request, controller.response
    controller.response.body
  end

  def morph selectors
    collect_morphs selectors, html
  end

  private
  # previously in Channel
  def collect_morphs selectors, html
    document = Nokogiri::HTML(html)
    selectors = selectors.select { |s| document.css(s).present? }
    selectors.map { |s| [s, document.css(s).inner_html] }
  end

  def commit_session(request, response)
    store = request.session.instance_variable_get("@by")
    store.commit_session request, response
  rescue => e
    message = "Failed to commit session! #{exception_message_with_backtrace(e)}"
    logger.error "\e[31m#{message}\e[0m"
  end

end
