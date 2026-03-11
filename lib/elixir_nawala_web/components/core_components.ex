defmodule ElixirNawalaWeb.CoreComponents do
  use Phoenix.Component
  use Gettext, backend: ElixirNawalaWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :flash, :map, required: true
  attr :kind, :atom, values: [:info, :error], required: true
  attr :id, :string, default: nil

  def flash(assigns) do
    ~H"""
    <div :if={msg = Phoenix.Flash.get(@flash, @kind)} id={@id} class={"flash #{@kind} toast-popup"} role="alert">
      <div class="flash-body">
        <p>{msg}</p>
      </div>
      <button
        type="button"
        class="flash-close"
        phx-click={JS.hide(to: "##{@id}")}
        onclick="this.closest('.flash')?.remove()"
        aria-label="Close notification"
      >
        X
      </button>
    </div>
    """
  end
end
