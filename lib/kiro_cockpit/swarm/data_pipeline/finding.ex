defmodule KiroCockpit.Swarm.DataPipeline.Finding do
  @moduledoc "Silver finding emitted by analyzers and eligible for Gold promotion."

  defstruct [:id, :tag, :type, :priority, :summary, :evidence, :session_id, :plan_id, :task_id]

  def new(attrs) do
    struct(__MODULE__, Map.put_new(attrs, :id, Ecto.UUID.generate()))
  end
end
