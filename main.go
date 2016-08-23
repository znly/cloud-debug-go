package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/oauth2/google"
)

var (
	scopes = []string{
		"https://www.googleapis.com/auth/cloud-platform",
		"https://www.googleapis.com/auth/cloud_debugger",
	}
)

func main() {
	var bindHost = flag.String("host", "localhost:7900", "bind host")
	var jsonKeyFile = flag.String("key", "key.json", "JSON key file")
	flag.Parse()

	keyFile, err := os.Open(*jsonKeyFile)
	if err != nil {
		panic(err)
	}

	keyData, err := ioutil.ReadAll(keyFile)
	if err != nil {
		panic(err)
	}

	cfg, err := google.JWTConfigFromJSON(keyData, scopes...)
	if err != nil {
		panic(err)
	}

	tokenSrc := cfg.TokenSource(context.Background())

	http.HandleFunc("/computeMetadata/v1/instance/service-accounts/default/token", func(w http.ResponseWriter, r *http.Request) {
		log.Println("Intercepting token call from", r.RemoteAddr)
		token, err := tokenSrc.Token()
		if err != nil {
			log.Println(err)
			return
		}

		json.NewEncoder(w).Encode(struct {
			AccessToken string `json:"access_token"`
			TokenType   string `json:"token_type"`
			ExpiresIn   int    `json:"expires_in"`
		}{
			token.AccessToken,
			token.TokenType,
			int(token.Expiry.Sub(time.Now().UTC()).Seconds()),
		})
	})

	http.HandleFunc("/computeMetadata/v1/instance/service-accounts/default/scopes", func(w http.ResponseWriter, r *http.Request) {
		log.Println("Intercepting scopes call from", r.RemoteAddr)
		fmt.Fprintln(w, strings.Join(scopes, "\n"))
	})

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		req, err := http.NewRequest(r.Method, "http://metadata.google.internal"+r.URL.Path, r.Body)
		if err != nil {
			log.Println(err)
			return
		}
		req.Header = r.Header
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			log.Println(err)
			return
		}
		hdr := w.Header()
		for key, values := range resp.Header {
			for _, value := range values {
				hdr.Add(key, value)
			}
		}
		io.Copy(w, resp.Body)
	})
	log.Println("Proxy started on", *bindHost)
	http.ListenAndServe(*bindHost, nil)
}
