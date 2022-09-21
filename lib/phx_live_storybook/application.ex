defmodule PhxLiveStorybook.Application do
  @moduledoc false

  use Application
  alias PhxLiveStorybook.Instrumenter

  @impl true
  def start(_type, _args) do
    Instrumenter.setup()

    Supervisor.start_link(
      [
        {Phoenix.PubSub, name: PhxLiveStorybook.PubSub},
        {PhxLiveStorybook.ExsLoader, []}
      ],
      strategy: :one_for_one,
      name: PhxLiveStorybook.Supervisor
    )
  end
end
