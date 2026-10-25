# SPDX-FileCopyrightText: 2026 ash_json_api contributors <https://github.com/ash-project/ash_json_api/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Test.Acceptance.ClientInputPoliciesTest do
  @moduledoc """
  The `sort` and `filter` parameters come from the client, so field policies and the read
  policies of related resources apply to them, on index and related routes.
  """
  use ExUnit.Case, async: true

  defmodule Comment do
    use Ash.Resource,
      domain: Test.Acceptance.ClientInputPoliciesTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshJsonApi.Resource]

    ets do
      private?(true)
    end

    json_api do
      type("comment")
    end

    policies do
      # A simple check, since ash_json_api's tests run without a SAT solver.
      policy action_type(:read) do
        authorize_if(actor_attribute_equals(:admin?, true))
      end

      policy action_type(:create) do
        authorize_if(always())
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:body, :string, public?: true)
    end

    relationships do
      belongs_to(:post, Test.Acceptance.ClientInputPoliciesTest.Post,
        public?: true,
        attribute_writable?: true
      )
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule Post do
    use Ash.Resource,
      domain: Test.Acceptance.ClientInputPoliciesTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshJsonApi.Resource]

    ets do
      private?(true)
    end

    json_api do
      type("post")

      routes do
        base("/posts")
        index(:read)
      end
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    field_policies do
      field_policy [:internal, :comment_count] do
        authorize_if(actor_attribute_equals(:admin?, true))
      end

      field_policy :* do
        authorize_if(always())
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:title, :string, public?: true)
      attribute(:internal, :string, public?: true)
    end

    relationships do
      belongs_to(:author, Test.Acceptance.ClientInputPoliciesTest.Author,
        public?: true,
        attribute_writable?: true
      )

      has_many(:comments, Test.Acceptance.ClientInputPoliciesTest.Comment, public?: true)
    end

    aggregates do
      count(:comment_count, :comments, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule Author do
    use Ash.Resource,
      domain: Test.Acceptance.ClientInputPoliciesTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer],
      extensions: [AshJsonApi.Resource]

    ets do
      private?(true)
    end

    json_api do
      type("author")

      routes do
        base("/authors")
        related(:posts, :read)
      end
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
    end

    relationships do
      has_many(:posts, Test.Acceptance.ClientInputPoliciesTest.Post, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end

  defmodule Domain do
    use Ash.Domain, otp_app: :ash_json_api, extensions: [AshJsonApi.Domain]

    json_api do
      log_errors?(false)
    end

    resources do
      resource(Comment)
      resource(Post)
      resource(Author)
    end
  end

  defmodule Router do
    use AshJsonApi.Router, domain: Domain
  end

  import AshJsonApi.Test

  @user %{admin?: false}
  @admin %{admin?: true}

  setup do
    Application.put_env(:ash_json_api, Domain, json_api: [test_router: Router])

    author = Ash.create!(Author, %{name: "ann"}, authorize?: false)

    posts =
      for {title, internal} <- [{"p1", "zz"}, {"p2", "mm"}, {"p3", "aa"}], into: %{} do
        post =
          Ash.create!(Post, %{title: title, internal: internal, author_id: author.id},
            authorize?: false
          )

        {title, post}
      end

    Ash.create!(Comment, %{body: "secret", post_id: posts["p1"].id}, authorize?: false)

    %{author: author}
  end

  defp titles(path, actor) do
    Domain
    |> get(path, status: 200, actor: actor)
    |> Map.get(:resp_body)
    |> Map.get("data")
    |> Enum.map(& &1["attributes"]["title"])
  end

  describe "index route" do
    test "sorting by a hidden field doesn't order by it" do
      assert titles("/posts?sort=internal", @user) == titles("/posts?sort=-internal", @user)
    end

    test "an admin sorts by the field" do
      assert titles("/posts?sort=internal", @admin) == ["p3", "p2", "p1"]
      assert titles("/posts?sort=-internal", @admin) == ["p1", "p2", "p3"]
    end

    # Needs Ash with the sort_input fix for aggregates with field policies, which raised.
    test "sorting by a hidden aggregate doesn't order by it" do
      assert titles("/posts?sort=comment_count", @user) ==
               titles("/posts?sort=-comment_count", @user)

      assert hd(titles("/posts?sort=-comment_count", @admin)) == "p1"
    end

    test "sorting by a visible field" do
      assert titles("/posts?sort=-title", @user) == ["p3", "p2", "p1"]
    end
  end

  describe "related route" do
    test "sorting by a hidden field doesn't order by it", %{author: author} do
      path = "/authors/#{author.id}/posts"
      assert titles(path <> "?sort=internal", @user) == titles(path <> "?sort=-internal", @user)
      assert titles(path <> "?sort=internal", @admin) == ["p3", "p2", "p1"]
    end

    test "filtering on a hidden field doesn't match", %{author: author} do
      path = "/authors/#{author.id}/posts"
      assert titles(path <> "?filter[internal]=zz", @user) == []
      assert titles(path <> "?filter[internal]=zz", @admin) == ["p1"]
    end

    test "filtering through a related record the actor can't read doesn't match", %{
      author: author
    } do
      path = "/authors/#{author.id}/posts"
      assert titles(path <> "?filter[comments][body]=secret", @user) == []
      assert titles(path <> "?filter[comments][body]=secret", @admin) == ["p1"]
    end

    test "filtering and sorting on visible fields", %{author: author} do
      path = "/authors/#{author.id}/posts"
      assert titles(path <> "?filter[title]=p2", @user) == ["p2"]
      assert titles(path <> "?sort=-title", @user) == ["p3", "p2", "p1"]
    end
  end
end
