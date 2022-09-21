defmodule PhxLiveStorybook.StoryLive do
  use PhxLiveStorybook.Web, :live_view

  alias Phoenix.{LiveView.JS, PubSub}
  alias PhxLiveStorybook.{ComponentStory, PageStory}
  alias PhxLiveStorybook.ExtraAssignsHelpers
  alias PhxLiveStorybook.Story.{Playground, PlaygroundPreviewLive}
  alias PhxLiveStorybook.{StoryNotFound, StoryTabNotFound}
  alias PhxLiveStorybook.{EventLog, Variation, VariationGroup}
  alias PhxLiveStorybook.ExtraAssignsHelpers
  alias PhxLiveStorybook.LayoutView

  import PhxLiveStorybook.NavigationHelpers

  def mount(_params, session, socket) do
    playground_topic = "playground-#{inspect(self())}"

    if connected?(socket) do
      PubSub.subscribe(PhxLiveStorybook.PubSub, playground_topic)
      PubSub.subscribe(PhxLiveStorybook.PubSub, "event_logs:#{inspect(self())}")
    end

    {:ok,
     assign(socket,
       otp_app: session["otp_app"],
       backend_module: session["backend_module"],
       assets_path: session["assets_path"],
       playground_error: nil,
       playground_preview_pid: nil,
       playground_topic: playground_topic
     )}
  end

  def handle_params(params, _uri, socket) when params == %{} do
    case first_component_story(socket) do
      nil -> {:noreply, socket}
      story -> {:noreply, patch_to(socket, story)}
    end
  end

  def handle_params(params = %{"story" => story_path}, _uri, socket) do
    case load_story(socket, story_path) do
      nil ->
        raise StoryNotFound, "unknown story #{inspect(story_path)}"

      story ->
        variation = current_variation(story, params)

        {:noreply,
         assign(socket,
           story: story,
           story_path: story_path,
           variation: variation,
           variation_id: if(variation, do: variation.id, else: nil),
           page_title: story.name,
           tab: current_tab(params, story),
           theme: current_theme(params, socket),
           variation_extra_assigns: init_variation_extra_assigns(story),
           playground_error: nil
         )
         |> push_event("lsb:close-sidebar", %{"id" => "#sidebar"})}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp first_component_story(socket) do
    socket.assigns.backend_module.all_leaves() |> Enum.at(0)
  end

  defp load_story(socket, story_param) do
    story_storybook_path = Path.join(["/" | story_param])
    socket.assigns.backend_module.find_story_by_path(story_storybook_path)
  end

  defp current_variation(%ComponentStory{variations: variations}, %{
         "variation_id" => variation_id
       }) do
    Enum.find(variations, &(to_string(&1.id) == variation_id))
  end

  defp current_variation(%ComponentStory{variations: [variation | _]}, _), do: variation
  defp current_variation(_, _), do: nil

  defp current_tab(params, story) do
    case Map.get(params, "tab") do
      nil -> default_tab(story)
      tab -> String.to_atom(tab)
    end
  end

  defp default_tab(%ComponentStory{}), do: :variations
  defp default_tab(%PageStory{navigation: []}), do: nil
  defp default_tab(%PageStory{navigation: [{tab, _, _} | _]}), do: tab

  defp current_theme(params, socket) do
    case Map.get(params, "theme") do
      nil -> default_theme(socket)
      theme -> String.to_atom(theme)
    end
  end

  defp default_theme(socket) do
    case socket.assigns.backend_module.config(:themes) do
      nil -> nil
      [{theme, _} | _] -> theme
    end
  end

  defp init_variation_extra_assigns(%ComponentStory{variations: variations}) do
    extra_assigns =
      for %Variation{id: variation_id} <- variations, into: %{}, do: {variation_id, %{}}

    for %VariationGroup{id: group_id, variations: variations} <- variations,
        %Variation{id: variation_id} <- variations,
        into: extra_assigns,
        do: {{group_id, variation_id}, %{}}
  end

  defp init_variation_extra_assigns(_), do: nil

  def render(assigns = %{story: _story}) do
    ~H"""
    <div class="lsb lsb-space-y-6 lsb-pb-12 lsb-flex lsb-flex-col lsb-h-[calc(100vh_-_7rem)] lg:lsb-h-[calc(100vh_-_4rem)]" id="story-live" phx-hook="StoryHook">
      <div class="lsb">
        <div class="lsb lsb-flex lsb-my-6 lsb-items-center">
          <h2 class="lsb lsb-flex-1 lsb-flex-nowrap lsb-whitespace-nowrap lsb-text-xl md:lsb-text-2xl lg:lsb-text-3xl lsb-m-0 lsb-font-extrabold lsb-tracking-tight lsb-text-indigo-600">
            <%= if icon = @story.icon do %>
              <i class={"lsb #{icon} lsb-pr-2 lsb-text-indigo-600"}></i>
            <% end %>
            <%= @story.name() %>
          </h2>

          <%=  @story |> navigation_tabs() |> render_navigation_tabs(assigns) %>
        </div>
        <div class="lsb lsb-text-base md:lsb-text-lg lsb-leading-7 lsb-text-slate-700">
          <%= @story.description() %>
        </div>
      </div>

      <%= render_content(@story, assigns) %>
    </div>
    """
  end

  def render(assigns), do: ~H""

  defp navigation_tabs(%ComponentStory{}) do
    [
      {:variations, "Stories", "far fa-eye"},
      {:playground, "Playground", "far fa-dice"},
      {:source, "Source", "far fa-file-code"}
    ]
  end

  defp navigation_tabs(%PageStory{navigation: navigation}), do: navigation

  defp render_navigation_tabs([], assigns), do: ~H""

  defp render_navigation_tabs(tabs, assigns) do
    ~H"""
    <div class="lsb lsb-flex lsb-flex-items-center">
      <!-- mobile version of navigation tabs -->
      <.form let={f} for={:navigation} id={"#{Macro.underscore(@story.module)}-navigation-form"} class="lsb story-nav-form lg:lsb-hidden">
        <%= select f, :tab, navigation_select_options(tabs), "phx-change": "set-tab", class: "lsb lsb-form-select lsb-w-full lsb-pl-3 lsb-pr-10 lsb-py-1 lsb-text-base lsb-border-gray-300 focus:lsb-outline-none focus:lsb-ring-indigo-600 focus:lsb-border-indigo-600 sm:lsb-text-sm lsb-rounded-md", value: @tab %>
      </.form>

      <!-- :lg+ version of navigation tabs -->
      <nav class="lsb story-tabs lsb-hidden lg:lsb-flex lsb-rounded-lg lsb-border lsb-bg-slate-100 lsb-hover:lsb-bg-slate-200 lsb-h-10 lsb-text-sm lsb-font-medium">
        <%= for {tab, label, icon} <- tabs do %>
          <a href="#" phx-click="set-tab" phx-value-tab={tab} class={"lsb lsb-group focus:lsb-outline-none lsb-flex lsb-rounded-md #{active_link(@tab, tab)}"}>
            <span class={active_span(@tab, tab)}>
              <i class={"lsb #{icon} lg:lsb-mr-2 group-hover:lsb-text-indigo-600 #{active_text(@tab, tab)}"}></i>
              <span class={"lsb group-hover:lsb-text-indigo-600 #{active_text(@tab, tab)}"}>
                <%= label %>
              </span>
            </span>
          </a>
        <% end %>
      </nav>
    </div>
    """
  end

  defp active_link(same, same), do: "lsb lsb-bg-white lsb-opacity-100"

  defp active_link(_tab, _current_tab) do
    "lsb lsb-ml-0.5 lsb-p-1.5 lg:lsb-pl-2.5 lg:lsb-pr-3.5 lsb-items-center lsb-text-slate-600"
  end

  defp active_span(same, same) do
    "lsb lsb-h-full lsb-rounded-md lsb-flex lsb-items-center lsb-bg-white lsb-shadow-sm \
    lsb-ring-opacity-5 lsb-text-indigo-600 lsb-p-1.5 lg:lsb-pl-2.5 lg:lsb-pr-3.5"
  end

  defp active_span(_tab, _current_tab), do: ""

  defp active_text(same, same), do: "lsb-text-indigo-600"
  defp active_text(_tab, _current_tab), do: "lsb -lsb-ml-0.5"

  defp navigation_select_options(tabs) do
    for {tab, label, _icon} <- tabs, do: {label, tab}
  end

  defp render_content(story = %ComponentStory{}, assigns = %{tab: :variations}) do
    ~H"""
    <div class="lsb lsb-space-y-12 lsb-pb-12" id={"story-variations-#{story_id(story)}"}>
      <%= for variation = %{id: variation_id, description: description} <- @story.variations(),
              variation_extra_assigns = variation_extra_assigns(variation, assigns) do %>
        <div id={anchor_id(variation)} class="lsb lsb-gap-x-4 lsb-grid lsb-grid-cols-5">

          <!-- Story description -->
          <div class="lsb lsb-col-span-5 lsb-font-medium hover:lsb-font-semibold lsb-mb-6 lsb-border-b lsb-border-slate-100 md:lsb-text-lg lsb-leading-7 lsb-text-slate-700 lsb-flex lsb-justify-between">
            <%= link to: "##{anchor_id(variation)}", class: "lsb variation-anchor-link" do %>
              <i class="lsb fal fa-link lsb-hidden -lsb-ml-8 lsb-pr-1 lsb-text-slate-400"></i>
              <%= if description do %>
                <%= description  %>
              <% else %>
                <%= variation_id |> to_string() |> String.capitalize() |> String.replace("_", " ") %>
              <% end %>
            <% end %>
            <%= live_patch to: path_to(@socket, story, %{tab: :playground, variation_id: variation.id, theme: @theme}), class: "lsb lsb-hidden" do %>
              <span class="lsb lsb-text-base lsb-font-light lsb-text-gray-300 hover:lsb-text-indigo-600 hover:lsb-font-medium ">
                Open in playground
                <i class="far fa-arrow-right"></i>
              </span>
            <% end %>
          </div>

          <!-- Variation component preview -->
          <div class="lsb lsb-border lsb-border-slate-100 lsb-rounded-md lsb-col-span-5 lg:lsb-col-span-2 lsb-mb-4 lg:lsb-mb-0 lsb-flex lsb-items-center lsb-justify-center lsb-p-2 lsb-bg-white lsb-shadow-sm">
            <%= if @story.container() == :iframe do %>
              <iframe
                phx-update="ignore"
                id={iframe_id(@story, variation)}
                src={live_storybook_path(@socket, :story_iframe, @story_path, variation_id: variation.id, theme: @theme)}
                class="lsb-w-full lsb-border-0"
                height="0"
                onload="javascript:(function(o){o.style.height=o.contentWindow.document.body.scrollHeight+'px';}(this));"
              />
            <% else %>
              <div class={LayoutView.sandbox_class(assigns)} style="width: 100%;">
                <%= @backend_module.render_variation(@story.module(), variation_id, variation_extra_assigns) %>
              </div>
            <% end %>
          </div>

          <!-- Variation code -->
          <div class="lsb lsb-border lsb-border-slate-100 lsb-bg-slate-800 lsb-rounded-md lsb-col-span-5 lg:lsb-col-span-3 lsb-group lsb-relative lsb-shadow-sm lsb-flex lsb-flex-col lsb-justify-center">
            <div phx-click={JS.dispatch("lsb:copy-code")} class="lsb lsb-hidden group-hover:lsb-block lsb-bg-slate-700 lsb-text-slate-500 hover:lsb-text-slate-100 lsb-z-10 lsb-absolute lsb-top-2 lsb-right-2 lsb-px-2 lsb-py-1 lsb-rounded-md lsb-cursor-pointer">
              <i class="lsb fa fa-copy lsb-text-inherit"></i>
            </div>
            <%= @backend_module.render_code(@story.module(), variation_id) %>
          </div>

        </div>
      <% end %>
    </div>
    """
  end

  defp render_content(%ComponentStory{}, assigns = %{tab: :source}) do
    ~H"""
    <div class="lsb lsb-flex-1 lsb-flex lsb-flex-col lsb-overflow-auto lsb-max-h-full">
      <%= @backend_module.render_source(@story.module) %>
    </div>
    """
  end

  defp render_content(%ComponentStory{}, assigns = %{tab: :playground}) do
    ~H"""
    <.live_component module={Playground} id="playground"
      story={@story} story_path={@story_path} backend_module={@backend_module}
      variation={@variation}
      playground_error={@playground_error}
      theme={@theme}
      topic={@playground_topic}
    />
    """
  end

  defp render_content(%ComponentStory{}, _assigns = %{tab: tab}),
    do: raise(StoryTabNotFound, "unknown story tab #{inspect(tab)}")

  defp render_content(%PageStory{}, assigns) do
    ~H"""
    <div class={"lsb lsb-pb-12 #{LayoutView.sandbox_class(assigns)}"}>
      <%= raw(@backend_module.render_page(@story.module, %{tab: @tab, theme: @theme})) %>
    </div>
    """
  end

  defp variation_extra_assigns(%Variation{id: variation_id}, assigns) do
    assigns.variation_extra_assigns
    |> Map.get(variation_id, %{})
    |> Map.put(:theme, assigns.theme)
  end

  defp variation_extra_assigns(%VariationGroup{id: group_id}, assigns) do
    for {{^group_id, variation_id}, extra_assigns} <- assigns.variation_extra_assigns,
        into: %{} do
      {variation_id,
       Map.merge(extra_assigns, %{id: "#{group_id}-#{variation_id}", theme: assigns.theme})}
    end
    |> Map.put(:theme, assigns.theme)
  end

  defp iframe_id(story, variation) do
    "iframe-#{story_id(story)}-variation-#{variation.id}"
  end

  defp story_id(story) do
    story.module |> Macro.underscore() |> String.replace("/", "_")
  end

  defp anchor_id(%{id: id}) do
    id |> to_string() |> String.replace("_", "-")
  end

  def handle_event("set-theme", %{"theme" => theme}, socket) do
    PubSub.broadcast!(
      PhxLiveStorybook.PubSub,
      socket.assigns.playground_topic,
      {:set_theme, String.to_atom(theme)}
    )

    {:noreply, socket |> assign(:theme, theme) |> patch_to(socket.assigns.story, %{theme: theme})}
  end

  def handle_event("set-tab", %{"tab" => tab}, socket) do
    {:noreply, patch_to(socket, socket.assigns.story, %{tab: tab})}
  end

  def handle_event("set-tab", %{"navigation" => %{"tab" => tab}}, socket) do
    {:noreply, patch_to(socket, socket.assigns.story, %{tab: tab})}
  end

  def handle_event("clear-playground-error", _, socket) do
    {:noreply, assign(socket, :playground_error, nil)}
  end

  def handle_event("assign", assign_params, socket = %{assigns: assigns}) do
    {variation_id, variation_extra_assigns} =
      ExtraAssignsHelpers.handle_set_variation_assign(
        assign_params,
        assigns.variation_extra_assigns,
        assigns.story
      )

    variation_extra_assigns = %{
      assigns.variation_extra_assigns
      | variation_id => variation_extra_assigns
    }

    {:noreply, assign(socket, :variation_extra_assigns, variation_extra_assigns)}
  end

  def handle_event("toggle", assign_params, socket = %{assigns: assigns}) do
    {variation_id, variation_extra_assigns} =
      ExtraAssignsHelpers.handle_toggle_variation_assign(
        assign_params,
        assigns.variation_extra_assigns,
        assigns.story
      )

    variation_extra_assigns = %{
      assigns.variation_extra_assigns
      | variation_id => variation_extra_assigns
    }

    {:noreply, assign(socket, :variation_extra_assigns, variation_extra_assigns)}
  end

  def handle_info({:playground_preview_pid, pid}, socket) do
    Process.monitor(pid)
    {:noreply, assign(socket, :playground_preview_pid, pid)}
  end

  def handle_info(event_log = %EventLog{view: PlaygroundPreviewLive}, socket) do
    send_update(Playground, id: "playground", new_event: event_log)
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, {:shutdown, :closed}}, socket) do
    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, socket)
      when socket.assigns.playground_preview_pid == pid do
    {:noreply, assign(socket, :playground_error, reason)}
  end

  def handle_info({:new_variations_attributes, variations_attributes}, socket) do
    send_update(Playground, id: "playground", new_variations_attributes: variations_attributes)
    {:noreply, socket}
  end

  def handle_info({:new_template_attributes, template_attributes}, socket) do
    send_update(Playground, id: "playground", new_template_attributes: template_attributes)
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end

defmodule PhxLiveStorybook.StoryNotFound do
  @moduledoc false
  defexception [:message, plug_status: 404]
end

defmodule PhxLiveStorybook.StoryTabNotFound do
  @moduledoc false
  defexception [:message, plug_status: 404]
end
