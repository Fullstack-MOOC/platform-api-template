/* eslint-disable no-undef */
// globals
let postId;
let token;

const getUniqueId = () => { return Cypress._.uniqueId(Date.now().toString()); };
const email = `${getUniqueId()}@test.com`;

describe('Platform-API WITH Authentication - ok to fail if you are on lab5 - use it.skip to skip these', () => {
  it('user signs up with email and password', () => {
    cy.request(
      'POST',
      '/api/signup',
      { email, password: 'password' },
    ).then((response) => {
      expect(response.status).to.eq(200);
      token = response.body.token;
    });
  });
  it('same user signs up with email and password, expecting fail 422', () => {
    cy.request({
      failOnStatusCode: false,
      method: 'POST',
      url: '/api/signup',
      body: { email, password: 'password' },
    }).then((response) => {
      expect(response.status).to.eq(422);
    });
  });
  it('user signs in with email and password', () => {
    cy.request({
      method: 'POST',
      url: '/api/signin',
      body: { email, password: 'password' },
    }).then((response) => {
      expect(response.status).to.eq(200);
      token = response.body.token;
    });
  });
  it('user makes post with out auth token, expecting failure code 401', () => {
    cy.request({
      failOnStatusCode: false,
      method: 'POST',
      url: '/api/posts',
      body: {
        title: 'authenticated test post',
        tags: 'words',
        content: 'this is a test post',
        coverUrl: 'https://media.giphy.com/media/uscuTAPrWqmqI/giphy.gif',
      },
    }).then((response) => {
      expect(response.status).to.eq(401);
    });
  });
  it('user makes post with auth token', () => {
    cy.request({
      method: 'POST',
      url: '/api/posts',
      headers: { authorization: token },
      body: {
        title: 'authenticated test post',
        tags: 'words',
        content: 'this is a test post',
        coverUrl: 'https://media.giphy.com/media/uscuTAPrWqmqI/giphy.gif',
      },
    }).then((response) => {
      expect(response.status).to.eq(200);
      expect(response.body.author).to.not.eq(undefined);
      postId = response.body.id;
    });
  });
  it('user deletes post with auth token', () => {
    cy.request({
      method: 'DELETE',
      url: `/api/posts/${postId}`,
      headers: { authorization: token },
    }).then((response) => {
      expect(response.status).to.eq(200);
    });
  });
  it('user signs in with email and wrong password, expecting fail code 401', () => {
    cy.request({
      failOnStatusCode: false,
      method: 'POST',
      url: '/api/signin',
      body: { email, password: 'passwordyword' },
    }).then((response) => {
      expect(response.status).to.eq(401);
    });
  });
});

describe('Lab5: CRUD operations', () => {
  it('user creates a post', () => {
    cy.request({
      method: 'POST',
      headers: { authorization: token },
      url: '/api/posts',
      body:
      {
        title: 'first post',
        tags: 'words',
        content: 'this is a test post',
        coverUrl: 'https://media.giphy.com/media/uscuTAPrWqmqI/giphy.gif',
      },
    }).then((response) => {
      expect(response.status).to.eq(200);
      postId = response.body.id;
    });
  });
  it('user retrieves a post', () => {
    cy.request({
      method: 'GET',
      headers: { authorization: token },
      url: `/api/posts/${postId}`,
    }).then((response) => {
      expect(response.status).to.eq(200);
      expect(response.body.title).to.eq('first post');
    });
  });
  it('user retrieves a bad post id, expecting failure code 404', () => {
    cy.request({
      failOnStatusCode: false,
      method: 'GET',
      headers: { authorization: token },
      url: '/api/posts/foobar',
    }).then((response) => {
      expect(response.status).to.eq(404);
    });
  });
  it('user updates a post', () => {
    cy.request({
      method: 'PUT',
      headers: { authorization: token },
      url: `/api/posts/${postId}`,
      body:
      {
        title: 'updated post',
        tags: 'words',
        content: 'this is a test post',
        coverUrl: 'https://media.giphy.com/media/uscuTAPrWqmqI/giphy.gif',
      },
    }).then((response) => {
      expect(response.status).to.eq(200);
      expect(response.body.title).to.eq('updated post');
    });
  });
  it('user deletes a post', () => {
    cy.request({
      method: 'DELETE',
      headers: { authorization: token },
      url: `/api/posts/${postId}`,
    }).then((response) => {
      expect(response.status).to.eq(200);
    });
  });
  it('retrieving deleted post, expecting error code 404', () => {
    cy.request({
      failOnStatusCode: false,
      method: 'GET',
      headers: { authorization: token },
      url: `/api/posts/${postId}`,
    }).then((res) => {
      expect(res.status).to.eq(404);
    });
  });
});
