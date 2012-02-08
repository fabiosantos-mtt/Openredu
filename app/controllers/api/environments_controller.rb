module Api
  class EnvironmentsController < ApiController

    def show
      @environment = Environment.find(params[:id])
      @environment.extend(EnvironmentRepresenter)

      respond_with @environment
    end

    def index
      @environments = Environment.all
      @environments.collect { |e| e.extend(EnvironmentRepresenter) }

      respond_with @environments
    end

    def destroy
      @environment = Environment.find(params[:id])
      @environment.extend(EnvironmentRepresenter)

      @environment.destroy

      respond_with @environment
    end

    def create
      @environment = Environment.new(params[:environment]) do |e|
        e.owner = current_user
      end
      @environment.extend(EnvironmentRepresenter)
      @environment.save

      respond_with @environment
    end

    def update
      @environment = Environment.find(params[:id])
      @environment.update_attributes(params[:environment])
      @environment.extend(EnvironmentRepresenter)

      respond_with @environment
    end
  end
end
