defmodule ElixirNawalaWeb.Layouts do
  use ElixirNawalaWeb, :html

  @site_name "Elixir Nawala"

  def site_name, do: @site_name

  def document_title(value) when is_binary(value) do
    title = String.trim(value)
    suffix = " | #{@site_name}"

    cond do
      title == "" ->
        @site_name

      String.ends_with?(title, suffix) ->
        title

      title == @site_name ->
        @site_name

      true ->
        "#{title}#{suffix}"
    end
  end

  def document_title(_), do: @site_name

  embed_templates "layouts/*"
end
